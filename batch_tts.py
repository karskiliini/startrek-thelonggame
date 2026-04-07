#!/usr/bin/env python3
"""Batch TTS wrapper for VibeVoice.

Loads the model once and processes a list of (txt_path, voice, wav_out) tuples.
Significantly faster than calling realtime_model_inference_from_file.py per block.

Reads a JSON list of jobs from stdin or from --jobs-file.
Each job is:
    {"txt": "path/to/text.txt", "voice": "Carter", "wav": "path/to/out.wav"}

Usage:
    echo '[{"txt":"a.txt","voice":"Carter","wav":"a.wav"}]' | python batch_tts.py
    python batch_tts.py --jobs-file jobs.json
"""

import argparse
import copy
import json
import os
import sys
import time
from pathlib import Path

# Make VibeVoice importable
VIBE_DIR = Path(__file__).parent / "VibeVoice"
sys.path.insert(0, str(VIBE_DIR))
sys.path.insert(0, str(VIBE_DIR / "demo"))

import torch
from vibevoice.modular.modeling_vibevoice_streaming_inference import VibeVoiceStreamingForConditionalGenerationInference
from vibevoice.processor.vibevoice_streaming_processor import VibeVoiceStreamingProcessor
from transformers.utils import logging as hf_logging

# Import VoiceMapper from the existing demo script
from realtime_model_inference_from_file import VoiceMapper  # noqa

hf_logging.set_verbosity_error()  # quieter output during batch


def load_model(model_path: str, device: str):
    """Load processor and model once."""
    print(f"[batch_tts] Loading processor & model from {model_path}", flush=True)
    t0 = time.time()

    if device == "mps" and not torch.backends.mps.is_available():
        print("[batch_tts] MPS not available. Falling back to CPU.", flush=True)
        device = "cpu"

    processor = VibeVoiceStreamingProcessor.from_pretrained(model_path)

    if device == "mps":
        load_dtype = torch.float32
        attn_impl = "sdpa"
    elif device == "cuda":
        load_dtype = torch.bfloat16
        attn_impl = "flash_attention_2"
    else:
        load_dtype = torch.float32
        attn_impl = "sdpa"

    try:
        if device == "mps":
            model = VibeVoiceStreamingForConditionalGenerationInference.from_pretrained(
                model_path,
                torch_dtype=load_dtype,
                attn_implementation=attn_impl,
                device_map=None,
            )
            model.to("mps")
        elif device == "cuda":
            model = VibeVoiceStreamingForConditionalGenerationInference.from_pretrained(
                model_path,
                torch_dtype=load_dtype,
                device_map="cuda",
                attn_implementation=attn_impl,
            )
        else:
            model = VibeVoiceStreamingForConditionalGenerationInference.from_pretrained(
                model_path,
                torch_dtype=load_dtype,
                device_map="cpu",
                attn_implementation=attn_impl,
            )
    except Exception as e:
        print(f"[batch_tts] Primary load failed: {e}", flush=True)
        model = VibeVoiceStreamingForConditionalGenerationInference.from_pretrained(
            model_path,
            torch_dtype=load_dtype,
            device_map=(device if device in ("cuda", "cpu") else None),
            attn_implementation="sdpa",
        )
        if device == "mps":
            model.to("mps")

    model.eval()
    model.set_ddpm_inference_steps(num_steps=5)

    print(f"[batch_tts] Model loaded in {time.time() - t0:.1f}s", flush=True)
    return processor, model, device


def generate_one(processor, model, device, voice_mapper, voice_cache, text: str, voice_name: str, wav_out: str, cfg_scale: float):
    """Generate one WAV file."""
    # Cache voice prefix tensors per voice so we only load them once per voice
    if voice_name not in voice_cache:
        voice_path = voice_mapper.get_voice_path(voice_name)
        voice_cache[voice_name] = torch.load(voice_path, map_location=device, weights_only=False)

    prefilled = voice_cache[voice_name]

    full_script = text.replace("\u2019", "'").replace("\u201c", '"').replace("\u201d", '"')

    inputs = processor.process_input_with_cached_prompt(
        text=full_script,
        cached_prompt=prefilled,
        padding=True,
        return_tensors="pt",
        return_attention_mask=True,
    )
    for k, v in inputs.items():
        if torch.is_tensor(v):
            inputs[k] = v.to(device)

    t0 = time.time()
    outputs = model.generate(
        **inputs,
        max_new_tokens=None,
        cfg_scale=cfg_scale,
        tokenizer=processor.tokenizer,
        generation_config={"do_sample": False},
        verbose=False,
        all_prefilled_outputs=copy.deepcopy(prefilled) if prefilled is not None else None,
    )
    gen_time = time.time() - t0

    os.makedirs(os.path.dirname(wav_out) or ".", exist_ok=True)
    processor.save_audio(outputs.speech_outputs[0], output_path=wav_out)
    return gen_time


def main():
    parser = argparse.ArgumentParser(description="Batch TTS processor")
    parser.add_argument("--model_path", default="microsoft/VibeVoice-Realtime-0.5B")
    parser.add_argument("--device", default="mps")
    parser.add_argument("--cfg_scale", type=float, default=1.3)
    parser.add_argument("--jobs-file", help="JSON file with job list (default: read from stdin)")
    args = parser.parse_args()

    # Read jobs
    if args.jobs_file:
        with open(args.jobs_file, "r") as f:
            jobs = json.load(f)
    else:
        jobs = json.load(sys.stdin)

    if not jobs:
        print("[batch_tts] No jobs to process.", flush=True)
        return

    print(f"[batch_tts] Processing {len(jobs)} jobs", flush=True)

    processor, model, device = load_model(args.model_path, args.device)
    voice_mapper = VoiceMapper()
    voice_cache = {}

    total_gen_time = 0.0
    failed = 0
    for i, job in enumerate(jobs, 1):
        txt_path = job["txt"]
        voice = job.get("voice", "Carter")
        wav_out = job["wav"]

        if not os.path.exists(txt_path):
            print(f"[batch_tts] {i}/{len(jobs)} SKIP (txt missing): {txt_path}", flush=True)
            failed += 1
            continue

        with open(txt_path, "r", encoding="utf-8") as f:
            text = f.read().strip()

        if not text:
            print(f"[batch_tts] {i}/{len(jobs)} SKIP (empty): {txt_path}", flush=True)
            failed += 1
            continue

        try:
            gen_time = generate_one(
                processor, model, device, voice_mapper, voice_cache,
                text, voice, wav_out, args.cfg_scale,
            )
            total_gen_time += gen_time
            print(f"[batch_tts] {i}/{len(jobs)} OK ({gen_time:.1f}s) {voice} → {wav_out}", flush=True)
        except Exception as e:
            print(f"[batch_tts] {i}/{len(jobs)} FAILED: {e}", flush=True)
            failed += 1

    print(f"[batch_tts] Done. {len(jobs) - failed}/{len(jobs)} generated in {total_gen_time:.1f}s", flush=True)


if __name__ == "__main__":
    main()
