#!/usr/bin/env python3
"""Opt-in real engine smoke test. Uses only the supplied synthetic fixture directory."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("binary", type=Path)
p.add_argument("fixtures", type=Path)
p.add_argument("output", type=Path)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
files = sorted(a.fixtures.glob("*.wav"))
assert files, "No WAV fixtures"
report = []
for engine in ("apple", "parakeet", "whisper"):
    destination = a.output / engine
    start = time.monotonic()
    result = subprocess.run([str(a.binary.resolve()), "transcribe", *map(str, files), "--engine", engine,
                             "--format", "json", "--output-dir", str(destination)], capture_output=True, timeout=300)
    assert result.returncode == 0, (engine, result.stderr.decode()[-500:])
    assert result.stdout == b"", "File exports must not leak transcripts to stdout"
    for file in files:
        document = json.loads((destination / (file.stem + ".json")).read_text())
        text = document["text"].lower()
        if file.stem == "silence":
            assert not text.strip(), (engine, "Silence hallucination")
        else:
            assert all(word in text for word in ("garden", "coffee", "meeting")), (engine, file.stem, "Missing fixture words")
            if file.stem == "long":
                # Base Whisper may spell coffee as Ko-fi; score recognition errors separately.
                # Coverage checks must detect dropped chunks, not conflate spelling with truncation.
                assert text.count("meeting") >= 7, (engine, "Long-file content lost")
                assert document["segments"][-1]["end"] > 36, (engine, "Long-file tail lost")
            segments = document["segments"]
            assert segments, (engine, "Missing timestamps")
            assert all(math.isfinite(s["start"]) and math.isfinite(s["end"]) and s["end"] >= s["start"] >= 0 for s in segments)
        report.append({"engine": engine, "fixture": file.stem, "words": len(text.split()), "segments": len(document["segments"]), "passed": True})
    print(f"CLI engine={engine} files={len(files)} seconds={time.monotonic() - start:.3f}", flush=True)

normal = a.fixtures / "normal.wav"
for format_name in ("text", "srt", "vtt"):
    path = a.output / ("export." + format_name)
    command = [str(a.binary.resolve()), "transcribe", str(normal), "--format", format_name, "--output", str(path)]
    result = subprocess.run(command, capture_output=True, timeout=60)
    assert result.returncode == 0, result.stderr.decode()[-500:]
    before = path.read_bytes()
    assert b"coffee" in before.lower()
    if format_name != "text": assert b" --> " in before
    result = subprocess.run(command, capture_output=True, timeout=10)
    assert result.returncode != 0 and path.read_bytes() == before, "Existing output was overwritten"

bad = subprocess.run([str(a.binary.resolve()), "download", "whisper", "--engine", "apple"], capture_output=True, timeout=10)
assert bad.returncode != 0
(a.output / "report.json").write_text(json.dumps(report, indent=2))
print(f"PASS {len(report)} engine/fixture combinations, three exports, overwrite refusal and invalid options")
