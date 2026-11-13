"""Writes the inputs of Headroom's own benchmark to files, one a scenario.
Usage: gen_headroom_bench.py HEADROOM_REPO OUT_DIR
Headroom's benchmark page (docs, benchmarks) is made by `benchmarks/bench_latency.py` in its repo, which builds each
scenario's tool output with a fixed seed. This calls that script's own generator and writes the tool output of each
scenario to OUT_DIR under a name made from the scenario's, so another tool can be given the same bytes."""
import os
import re
import sys

repo, out = os.path.abspath(sys.argv[1]), sys.argv[2]
sys.path.insert(0, repo)
from benchmarks.bench_latency import generate_scenarios  # noqa: E402

os.makedirs(out, exist_ok=True)
for scenario in generate_scenarios():
    tool = [m for m in scenario.messages if m.get("role") == "tool"]
    if len(tool) != 1 or not isinstance(tool[0].get("content"), str):
        continue
    name = re.sub(r"[^a-z0-9]+", "-", scenario.name.lower()).strip("-")
    with open(f"{out}/{name}.txt", "w", encoding="utf-8") as f:
        f.write(tool[0]["content"])
    print(f"{name}\t{scenario.name}\t{len(tool[0]['content'])} bytes")
