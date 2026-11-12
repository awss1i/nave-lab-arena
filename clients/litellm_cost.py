"""Costs calls with LiteLLM's own cost_per_token, on LiteLLM's own price list.
`litellm_cost.py gen DIR` writes the usages for both entrants: DIR/costs.txt in the format Nave's p009 reads, and
DIR/costs.json for this script. `litellm_cost.py time DIR ITERS` costs them all and prints the total."""
import json
import os
import random
import sys
import time
import warnings

warnings.filterwarnings("ignore")
os.environ["LITELLM_LOCAL_MODEL_COST_MAP"] = "True"
os.environ["LITELLM_LOG"] = "ERROR"
import litellm  # noqa: E402

litellm.suppress_debug_info = True
d = sys.argv[2]
if sys.argv[1] == "gen":
    random.seed(3)
    pico = lambda x: round((x or 0) * 1e12)
    lines, rows = [], []
    # Models priced by the token with no tier, so both entrants are given the same four prices.
    models = [m for m, info in litellm.model_cost.items() if info.get("mode") == "chat" and info.get("input_cost_per_token") and info.get("output_cost_per_token")
              and not any("above" in k or "per_second" in k or "per_character" in k or "per_image" in k or "per_audio" in k or "per_query" in k or "per_request" in k or "priority" in k or "flex" in k or "batches" in k for k in info)][:400]
    for m in models:
        info = litellm.model_cost[m]
        for _ in range(5):
            i, o = random.randint(1, 40_000), random.randint(1, 4000)
            try:
                pc, cc = litellm.cost_per_token(model=m, prompt_tokens=i, completion_tokens=o)
            except Exception:
                break
            want = round((pc + cc) * 1e9)
            got = (i * pico(info["input_cost_per_token"]) + o * pico(info["output_cost_per_token"]) + 500) // 1000
            if abs(want - got) > 1:
                break  # LiteLLM prices this model some other way, so it's left out for both
            lines.append(" ".join(map(str, [pico(info["input_cost_per_token"]), pico(info["output_cost_per_token"]), 0, 0, 0, 0, 0, 0, 0, i, o, 0, 0])))
            rows.append([m, i, o])
    open(f"{d}/costs.txt", "w").write("\n".join(lines) + "\n")
    # The model's name for each line, so Nave's entrant also starts from the name and looks the price up.
    open(f"{d}/costs.txt.models", "w").write("\n".join(r[0] for r in rows) + "\n")
    json.dump(rows, open(f"{d}/costs.json", "w"))
    print(f"{len(rows)} usages over {len({r[0] for r in rows})} models")
else:
    rows, iters = json.load(open(f"{d}/costs.json")), int(sys.argv[3])
    t = time.perf_counter()
    for _ in range(iters):
        total = 0
        for m, i, o in rows:
            pc, cc = litellm.cost_per_token(model=m, prompt_tokens=i, completion_tokens=o)
            total += round((pc + cc) * 1e9)
    ns = (time.perf_counter() - t) * 1e9 / (iters * len(rows))
    print(f"{len(rows)} costs, {round(total / 1000)} micro-dollars in all")
    print(f"metric ns_per_cost={ns:.1f}", file=sys.stderr)
