"""Runs a personal-data scanner over the prompts with planted values and says how many of them it found.
Usage: pii.py nave|presidio|llm-guard DIR. DIR holds pii.txt, pii.jsonl and pii-planted.tsv from gen_pii.py.

Each tool is loaded first and then timed over every prompt, one prompt at a time, as a gateway would call it.
Presidio runs with spaCy's small English model and only the four kinds planted, which is its quickest setting for
them. LLM Guard runs its Anonymize scanner, which is Presidio with a transformer for names."""
import json
import os
import subprocess
import sys
import time
import warnings

warnings.filterwarnings("ignore")
tool, d = sys.argv[1], sys.argv[2]
prompts = [json.loads(l) for l in open(f"{d}/pii.jsonl")]
planted = [l.split("\t") for l in open(f"{d}/pii-planted.tsv").read().splitlines()]
size = sum(len(p.encode()) for p in prompts)
found = [set() for _ in prompts]   # per prompt, the strings a tool flagged
findings = 0
if tool == "nave":
    run = subprocess.run(["bin/p011", "fast", f"{d}/pii.txt", "1"], capture_output=True, text=True, check=True)
    raw = [p.encode() for p in prompts]
    for line in run.stdout.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0].isdigit() and parts[2].isdigit() and parts[3].isdigit():
            i, s, e = int(parts[0]), int(parts[2]), int(parts[3])
            found[i].add(raw[i][s:e].decode())
            findings += 1
    seconds = float(next(l.split("=")[1] for l in run.stderr.splitlines() if l.startswith("metric ns_per_text="))) * len(prompts) / 1e9
elif tool == "presidio":
    from presidio_analyzer import AnalyzerEngine
    from presidio_analyzer.nlp_engine import NlpEngineProvider

    engine = AnalyzerEngine(nlp_engine=NlpEngineProvider(nlp_configuration={"nlp_engine_name": "spacy", "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}]}).create_engine(), supported_languages=["en"])
    kinds = ["EMAIL_ADDRESS", "CREDIT_CARD", "US_SSN", "IP_ADDRESS"]
    engine.analyze(text=prompts[0], language="en", entities=kinds)
    t = time.perf_counter()
    for i, p in enumerate(prompts):
        for r in engine.analyze(text=p, language="en", entities=kinds):
            found[i].add(p[r.start:r.end])
            findings += 1
    seconds = time.perf_counter() - t
elif tool == "llm-guard":
    from llm_guard.input_scanners import Anonymize
    from llm_guard.vault import Vault

    scanner = Anonymize(Vault(), entity_types=["EMAIL_ADDRESS", "CREDIT_CARD", "US_SSN", "IP_ADDRESS"])
    scanner.scan(prompts[0])
    t = time.perf_counter()
    cleaned = []
    for p in prompts:
        out, _, _ = scanner.scan(p)
        cleaned.append(out)
    seconds = time.perf_counter() - t
    # It hands back the prompt with each value replaced, so a planted value counts as found when it's gone.
    for i, (p, out) in enumerate(zip(prompts, cleaned)):
        findings += out.count("[REDACTED_")
        for n, kind, value in planted:
            if int(n) == i and value not in out:
                found[i].add(value)
else:
    raise SystemExit(f"no scanner {tool}")
hit = sum(1 for n, kind, value in planted if any(value in f or f in value for f in found[int(n)]))
print("scanned")
print(f"metric planted_found={hit}\nmetric planted={len(planted)}\nmetric findings={findings}\nmetric us_per_prompt={seconds * 1e6 / len(prompts):.1f}\nmetric mb_per_s={size / 1e6 / seconds:.2f}", file=sys.stderr)
