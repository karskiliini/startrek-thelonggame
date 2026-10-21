"""No real Claude, git mutation, network or TTS calls."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def editor(tmp_path, monkeypatch):
    monkeypatch.setenv('VOICE_EDIT_TOKEN', 't' * 48)
    spec = importlib.util.spec_from_file_location('voice_edit_under_test', Path(__file__).parents[1] / 'voice_edit_server.py')
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    monkeypatch.setattr(mod, 'PROJECT_DIR', tmp_path)
    (tmp_path / 'v1').mkdir()
    scene = tmp_path / 'v1' / '00_scene.md'
    scene.write_text('Original scene\n')
    (tmp_path / '.git').mkdir()
    (tmp_path / '.git' / 'config').write_text('private configuration')
    state = {'dirty': False, 'calls': [], 'real_run_claude': mod.run_claude}

    def fake_run(cmd, **kwargs):
        state['calls'].append(cmd)
        if cmd[0] == 'claude':
            assert Path(kwargs['cwd']) != tmp_path
            assert not list(Path(kwargs['cwd']).iterdir())
            return subprocess.CompletedProcess(cmd, 0, json.dumps({'status': 'proposed', 'message': 'Changed the scene', 'scene': 'Proposed scene\n'}), '')
        if cmd[:2] == ['git', 'status']:
            return subprocess.CompletedProcess(cmd, 0, ' M v1/00_scene.md' if state['dirty'] else '', '')
        if cmd[:2] == ['git', 'diff']:
            return subprocess.CompletedProcess(cmd, 0, 'diff proposal', '')
        if cmd[:2] == ['git', 'checkout']:
            scene.write_text('Original scene\n')
        return subprocess.CompletedProcess(cmd, 0, '', '')

    monkeypatch.setattr(mod.subprocess, 'run', fake_run)
    monkeypatch.setattr(mod.subprocess, 'Popen', lambda *a, **k: (_ for _ in ()).throw(AssertionError('TTS must be faked explicitly')))
    monkeypatch.setattr(mod, 'run_claude', lambda scene_file, prompt, directory: (lambda r: (r.returncode, r.stdout.strip()))(fake_run(mod.claude_command(scene_file, prompt), cwd=directory)))
    client = TestClient(mod.app)
    headers = {'Authorization': 'Bearer ' + 't' * 48}
    payload = {'transcription': 'Change this scene', 'scene_file': 'v1/00_scene.md', 'version': 'v1'}
    return mod, client, headers, payload, scene, state


@pytest.mark.parametrize('path', ['.git/config', 'v1', 'v1/../.git/config', '/etc/passwd'])
def test_only_scene_files(editor, path):
    _, client, headers, payload, _, state = editor
    payload['scene_file'] = path
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code in (400, 404, 422)
    assert not any(c[0] == 'claude' for c in state['calls'])


def test_symlinks_rejected(editor):
    _, client, headers, payload, scene, _ = editor
    scene.unlink()
    scene.symlink_to(scene.parents[1] / '.git/config')
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code == 400


def test_dirty_scene_never_reverted(editor):
    _, client, headers, payload, scene, state = editor
    scene.write_text('Uncommitted user work\n')
    state['dirty'] = True
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code == 409
    assert scene.read_text() == 'Uncommitted user work\n'
    assert not any(c[1] in ('checkout', 'reset') for c in state['calls'])


def propose(editor):
    _, client, headers, payload, _, _ = editor
    response = client.post('/api/voice-edit', headers=headers, json=payload)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data['status'] == 'pending_approval'
    return {'scene_file': data['scene_file'], 'proposal_id': data['proposal_id']}


def test_proposal_isolated_and_cancel_preserves_new_work(editor):
    _, client, headers, _, scene, state = editor
    proposal = propose(editor)
    assert scene.read_text() == 'Original scene\n'
    claude = next(c for c in state['calls'] if c[0] == 'claude')
    assert '--restricted' in claude and '--strict-mcp-config' in claude
    assert claude[claude.index('--tools') + 1] == ''
    assert '--disable-slash-commands' in claude and claude[claude.index('--disallowedTools') + 1] == '*'
    scene.write_text('User edited after proposal\n')
    assert client.post('/api/voice-edit-cancel', headers=headers, json=proposal).status_code == 200
    assert scene.read_text() == 'User edited after proposal\n'
    assert not any(c[:2] == ['git', 'checkout'] for c in state['calls'])


def test_unbound_approval_cannot_commit(editor):
    _, client, headers, _, _, state = editor
    forged = {'scene_file': 'v1/00_scene.md', 'proposal_id': 'x' * 43, 'transcription': 'Anything'}
    assert client.post('/api/voice-edit-approve', headers=headers, json=forged).status_code == 409
    assert not any(c[:2] == ['git', 'commit'] for c in state['calls'])


def test_changed_scene_and_replayed_proposal_cannot_commit(editor):
    _, client, headers, _, scene, state = editor
    proposal = propose(editor)
    scene.write_text('Concurrent user work\n')
    assert client.post('/api/voice-edit-approve', headers=headers, json=proposal).status_code == 409
    assert scene.read_text() == 'Concurrent user work\n'
    assert not any(c[:2] == ['git', 'commit'] for c in state['calls'])
    client.post('/api/voice-edit-cancel', headers=headers, json=proposal)
    assert client.post('/api/voice-edit-approve', headers=headers, json=proposal).status_code == 409


def test_approval_commits_only_selected_scene(editor, monkeypatch):
    mod, client, headers, _, scene, state = editor
    proposal = propose(editor)
    monkeypatch.setattr(mod, 'trigger_tts', lambda: True, raising=False)
    assert client.post('/api/voice-edit-approve', headers=headers, json=proposal).json()['status'] == 'approved'
    assert scene.read_text() == 'Proposed scene\n'
    commit = next(c for c in state['calls'] if c[:2] == ['git', 'commit'])
    assert '--only' in commit and commit[-2:] == ['--', 'v1/00_scene.md']
    assert not any(c[:2] == ['git', 'pull'] for c in state['calls'])
    assert client.post('/api/voice-edit-approve', headers=headers, json=proposal).status_code == 409


def test_auth_origin_and_size_limits(editor, monkeypatch):
    mod, client, headers, payload, _, state = editor
    assert client.post('/api/voice-edit', json=payload).status_code == 401
    assert client.post('/api/voice-edit', headers={**headers, 'Origin': 'null'}, json=payload).status_code == 403
    assert client.post('/api/voice-edit', headers={**headers, 'Origin': 'https://evil.example'}, json=payload).status_code == 403
    assert client.post('/api/voice-edit', headers=headers, content=b'x' * 17000).status_code == 413
    payload['transcription'] = 'x' * 8001
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code == 422
    monkeypatch.setattr(mod, 'AUTH_TOKEN', 'weak')
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code == 503


def test_forged_cancel_and_expired_proposal(editor, monkeypatch):
    mod, client, headers, _, scene, _ = editor
    proposal = propose(editor)
    forged = {**proposal, 'proposal_id': 'f' * 43}
    assert client.post('/api/voice-edit-cancel', headers=headers, json=forged).status_code == 409
    assert client.post('/api/voice-edit', headers=headers, json={'transcription':'Again', 'scene_file':proposal['scene_file'], 'version':'v1'}).status_code == 409
    expires = mod.pending.expires_at
    monkeypatch.setattr(mod, 'monotonic', lambda: expires + 1)
    assert client.post('/api/voice-edit-approve', headers=headers, json=proposal).status_code == 409
    assert scene.read_text() == 'Original scene\n'


def test_failed_commit_restores_only_our_candidate(editor, monkeypatch):
    mod, client, headers, _, scene, _ = editor
    proposal = propose(editor)
    original_git = mod.git

    def fail_commit(*args, **kwargs):
        if args[0] == 'commit':
            raise mod.HTTPException(503, 'Mock commit failure')
        return original_git(*args, **kwargs)

    monkeypatch.setattr(mod, 'git', fail_commit)
    assert client.post('/api/voice-edit-approve', headers=headers, json=proposal).status_code == 503
    assert scene.read_text() == 'Original scene\n'


def test_timeout_kills_and_reaps_only_fake_process_group(editor, monkeypatch, tmp_path):
    mod, _, _, _, scene, state = editor
    events = []

    class FakeProcess:
        pid = 123456
        returncode = -9

        def communicate(self, *args, **kwargs):
            if 'timeout' in kwargs:
                events.append('started')
                raise subprocess.TimeoutExpired('fake claude', 180)
            events.append('reaped')

    monkeypatch.setattr(mod.subprocess, 'Popen', lambda *args, **kwargs: FakeProcess())
    monkeypatch.setattr(mod.os, 'killpg', lambda pid, sig: events.append((pid, sig)))
    with pytest.raises(mod.HTTPException) as exc:
        state['real_run_claude']('v1/00_scene.md', 'Fake prompt', tmp_path)
    assert exc.value.status_code == 504
    assert events == ['started', (123456, mod.signal.SIGKILL), 'reaped']
    assert scene.read_text() == 'Original scene\n'


def test_non_json_model_output_is_rejected_without_writes(editor, monkeypatch):
    mod, client, headers, payload, scene, _ = editor
    monkeypatch.setattr(mod, 'run_claude', lambda *args: (0, 'Unexpected response'))
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code == 502
    assert scene.read_text() == 'Original scene\n'


@pytest.mark.parametrize(('field', 'value'), [
    ('transcription', 'Change\x00this scene'),
    ('transcription', 'x' * 81 + '\x00'),
    ('scene_file', 'v1/00_scene.md\x00'),
])
def test_nul_request_fields_are_rejected_before_any_work(editor, field, value):
    mod, client, headers, payload, scene, state = editor
    payload[field] = value
    assert client.post('/api/voice-edit', headers=headers, json=payload).status_code == 422
    assert mod.pending is None
    assert state['calls'] == []
    assert scene.read_text() == 'Original scene\n'


def test_nul_approval_path_cannot_write_or_commit_a_proposal(editor):
    _, client, headers, _, scene, state = editor
    proposal = propose(editor)
    state['calls'].clear()
    invalid = {**proposal, 'scene_file': proposal['scene_file'] + '\x00'}
    assert client.post('/api/voice-edit-approve', headers=headers, json=invalid).status_code == 422
    assert state['calls'] == []
    assert scene.read_text() == 'Original scene\n'
    # Invalid approval must not consume or change the legitimate proposal.
    assert client.post('/api/voice-edit-cancel', headers=headers, json=proposal).status_code == 200
