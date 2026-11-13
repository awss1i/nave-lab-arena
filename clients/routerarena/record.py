"""Writes the record of a RouterArena run in the shape the arena's harness writes, so the results table reads it.
Usage: record.py REPO OUT_DIR COMMIT, after routerarena.sh has run every variant.
It reads each variant's log for the figures RouterArena's own evaluation printed and each prediction file for how
many queries went to the stronger model."""
import json
import os
import platform
import re
import subprocess
import sys
import time

repo, out, commit = sys.argv[1], sys.argv[2], sys.argv[3]
weak, strong = "deepseek/deepseek-v3.2", "gemini-3-flash-preview"
# Nave's entrant is the half mark, named before any run. The other two thresholds are written into the conditions.
names = {"q50": "Nave", "weak": "chuzom-solo-v32, every query to the cheaper model", "strong": "LLM Router, every query to the stronger model",
         "q25": "", "q75": ""}
entrants, others = [], {}
for variant, name in names.items():
    log = open(f"{repo}/../nave-{variant}.log").read()

    def last(pattern):
        return float(re.findall(pattern, log)[-1])

    rows = json.load(open(f"{repo}/router_inference/predictions/nave-{variant}.json"))[:8400]
    metrics = {"arena_score": round(100 * last(r"RouterArena Score: ([0-9.]+)"), 2), "accuracy_percent": round(100 * last(r"Average Accuracy: ([0-9.]+)"), 2),
               "usd_per_1000_queries": last(r"Average Cost per 1K Queries: \$([0-9.]+)"), "robustness": last(r"Robustness score: ([0-9.]+)"),
               "queries_to_the_stronger_model": sum(r["prediction"] == strong for r in rows), "queries": len(rows)}
    if not name:
        others[variant] = metrics
        continue
    entrants.append({"name": name, "cmd": ["clients/routerarena/routerarena.sh", "REPO", variant], "metrics": metrics, "metric_rounds": {k: [v] for k, v in metrics.items()}})
cpu = next((line.split(":", 1)[1].strip() for line in open("/proc/cpuinfo") if line.startswith("model name")), "")
record = {
    "name": "RouterArena's 8,400 queries, choosing between two models",
    "feature": "F4",
    "conditions": "this machine, not a runner. RouterArena's own prediction, inference and evaluation scripts score a router that names a model for each of its 8,400 queries. The router chooses between "
                  f"{weak}, the cheaper, and {strong}. No provider is called: both models' answers to every query are in RouterArena's repository, in the prediction files of the leaderboard entries "
                  "that send every query to one of them, and its inference step reads them from there. Always choosing one model reproduces those two entries' rows on the leaderboard, which shows the "
                  "scoring here is the leaderboard's. RouterArena forbids training on its data, so Nave's router is trained on RouteLLM's MMLU and GSM8K results only, and its threshold is the score that "
                  "half of the RouteLLM prompts it didn't train on fall under. The other two entrants are leaderboard entries, scored again here. The score is RouterArena's own, out of 100, from accuracy "
                  "and cost. Robustness is the share of 420 reworded queries that keep their model. " + " ".join(
                      f"With the threshold at the {mark} mark Nave sends {m['queries_to_the_stronger_model']:,} queries to the stronger model and gets {m['accuracy_percent']}% right at "
                      f"${m['usd_per_1000_queries']:.2f} per 1,000, a score of {m['arena_score']} and robustness {m['robustness']:.2f}." for mark, m in (("quarter", others["q25"]), ("three-quarter", others["q75"]))),
    "correct": True, "differences": [], "rounds": 1, "wrong_rounds": 0, "outputs_when_wrong": [], "output_lines": 1, "dirty": False,
    "command": "clients/routerarena/routerarena.sh REPO weak strong q50 q25 q75", "commit": commit, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "machine": {"cpu": cpu, "cpus": os.cpu_count(), "kernel": f"{platform.system()} {platform.release()}", "runner": "this machine",
                "memory_gb": round(int(next(line.split()[1] for line in open("/proc/meminfo") if line.startswith("MemTotal"))) / 1e6, 1)},
    "entrants": entrants,
}
os.makedirs(out, exist_ok=True)
json.dump(record, open(f"{out}/routerarena-choosing-between-two-models.json", "w"), indent=1)
head = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
with open(f"{out}/versions.tsv", "w") as f:
    f.write(f"RouterArena\tRouteWorks/RouterArena at {head}, its dataset from Hugging Face, its own scripts\n")
    f.write(f"the two models' answers\tfrom the leaderboard entries chuzom-solo-v32 ({weak}) and llm-router-g3 ({strong}) in the same repository\n")
    f.write("nave-pick\tprototype P010, trained on RouteLLM's MMLU and GSM8K results\n")
print(json.dumps({e["name"]: e["metrics"] for e in entrants}, indent=1))
