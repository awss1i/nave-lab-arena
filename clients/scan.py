"""Runs a secret scanner over the text with planted secrets and says how many of them it found.
Usage: scan.py nave|gitleaks DIR [GITLEAKS_BINARY]. DIR holds secrets.txt and planted.tsv from gen_secrets.py."""
import json
import os
import subprocess
import sys
import time

tool, d = sys.argv[1], sys.argv[2]
planted = [l.split("\t")[1] for l in open(f"{d}/planted.tsv").read().splitlines()]
size = os.path.getsize(f"{d}/secrets.txt")
if tool == "nave":
    # Timed the way gitleaks is: one scan as a whole process, start and file read included.
    t = time.perf_counter()
    run = subprocess.run(["bin/p011", "file", f"{d}/secrets.txt", "1"], capture_output=True, text=True, check=True)
    speed = size / 1e6 / (time.perf_counter() - t)
    found = {l.split("\t", 1)[1] for l in run.stdout.splitlines() if "\t" in l}
    findings = len(run.stdout.splitlines())
    inside = float(next(l.split("=")[1] for l in run.stderr.splitlines() if l.startswith("metric mb_per_s=")))
    print(f"metric mb_per_s_scan_alone={inside:.1f}", file=sys.stderr)
else:
    report = f"{d}/gitleaks.json"
    t = time.perf_counter()
    subprocess.run([sys.argv[3], "dir", f"{d}/secrets.txt", "--report-format", "json", "--report-path", report, "--no-banner", "--exit-code", "0", "--log-level", "error"], capture_output=True, text=True)
    speed = size / 1e6 / (time.perf_counter() - t)
    results = json.load(open(report))
    found = {r["Secret"] for r in results}
    findings = len(results)
hit = sum(1 for p in planted if any(p in f or f in p for f in found))
print("scanned")
print(f"metric planted_found={hit}\nmetric planted={len(planted)}\nmetric findings={findings}\nmetric mb_per_s={speed:.1f}", file=sys.stderr)
