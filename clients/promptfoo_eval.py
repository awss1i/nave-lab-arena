"""Runs a suite written for Nave's p017 through promptfoo, against the same stand-in model, and prints the same lines.
Usage: promptfoo_eval.py MODULE_DIR SUITE.json CONCURRENCY. MODULE_DIR holds node_modules/promptfoo."""
import json
import os
import subprocess
import sys
import time

modules, suite_path, conc = sys.argv[1], sys.argv[2], sys.argv[3]
suite = json.load(open(suite_path))
target = suite["targets"][0]
work = "run/promptfoo"
os.makedirs(work, exist_ok=True)
config = {
    "prompts": [{"label": p["id"], "raw": json.dumps(p["messages"])} for p in suite["prompts"]],
    "providers": [{"id": f"openai:chat:{target['model']}", "config": {"apiBaseUrl": target["url"].rsplit("/chat/completions", 1)[0], "apiKey": os.environ.get("LLM_KEY", "local")}}],
    "tests": [{"vars": t["vars"], "assert": [{"type": a["type"], "value": a["value"]} for a in t["assert"]]} for t in suite["tests"]],
}
json.dump(config, open(f"{work}/config.json", "w"))
env = {**os.environ, "PROMPTFOO_DISABLE_TELEMETRY": "1", "PROMPTFOO_DISABLE_UPDATE": "1", "PROMPTFOO_CONFIG_DIR": f"{os.getcwd()}/{work}/home", "OPENAI_API_KEY": os.environ.get("LLM_KEY", "local")}
t = time.perf_counter()
run = subprocess.run(["node", f"{modules}/node_modules/promptfoo/dist/src/main.js", "eval", "-c", f"{work}/config.json", "--no-cache", "--no-progress-bar", "--no-table", "--no-write", "--max-concurrency", conc, "-o", f"{work}/out.json"],
                     env=env, capture_output=True, text=True)
s = time.perf_counter() - t
try:
    results = json.load(open(f"{work}/out.json"))["results"]["results"]
except (OSError, KeyError, ValueError):
    print("promptfoo gave no results:", run.stdout[-400:], run.stderr[-400:])
    sys.exit(1)
tests = len(suite["tests"])
for p in suite["prompts"]:
    passed = sum(1 for r in results if r["prompt"]["label"] == p["id"] and r["success"])
    print(f"{p['id']} on {target['id']}: {passed} of {tests} passed")
print(f"metric cases_per_s={len(results) / s:.1f}\nmetric seconds={s:.3f}", file=sys.stderr)
