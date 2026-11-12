"""Costs calls with a pricing library, on the usages the cost race gives Nave and LiteLLM, for the models the
library's own price list knows. Usage: cost_libs.py tokencost|genai-prices DIR ITERS

A library's prices are its own, so its total isn't compared with another's. It prints how many of the usages it
could price, and the time for each of those."""
import json
import sys
import time
import warnings

warnings.filterwarnings("ignore")
lib, d, iters = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = json.load(open(f"{d}/costs.json"))
if lib == "tokencost":
    from tokencost import calculate_cost_by_tokens

    def cost(model, i, o):
        return float(calculate_cost_by_tokens(i, model, "input") + calculate_cost_by_tokens(o, model, "output"))
elif lib == "genai-prices":
    from genai_prices import Usage, calc_price

    def cost(model, i, o):
        return float(calc_price(Usage(input_tokens=i, output_tokens=o), model_ref=model).total_price)
else:
    raise SystemExit(f"no library {lib}")

known = []
for m, i, o in rows:
    try:
        cost(m, i, o)
        known.append((m, i, o))
    except Exception:
        pass
if not known:
    raise SystemExit(f"{lib} priced none of the usages")
t = time.perf_counter()
for _ in range(iters):
    total = 0.0
    for m, i, o in known:
        total += cost(m, i, o)
ns = (time.perf_counter() - t) * 1e9 / (iters * len(known))
print(f"{len(known)} of {len(rows)} usages priced")
print(f"metric ns_per_cost={ns:.1f}\nmetric usages_priced={len(known)}\nmetric usages={len(rows)}", file=sys.stderr)
