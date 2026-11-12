"""Costs calls with a pricing library, on the usages the cost race gives Nave and LiteLLM, for the models the
library's own price list knows. Usage: cost_libs.py tokencost|genai-prices|models.dev|portkey-models DIR ITERS

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
elif lib in ("models.dev", "portkey-models"):
    # Two price lists that are data and not code: models.dev's api.json and the JSON files in Portkey's models
    # repo. Each is read into a table here, so the time printed is this script's table lookup and says nothing
    # about them. What they're in the race for is how many of the usages their list can price.
    import glob
    import os

    prices_dir = os.path.join(os.environ["ARENA_TOOLS"], "src", "prices")
    table = {}
    if lib == "models.dev":
        for provider, entry in json.load(open(f"{prices_dir}/models-dev.json")).items():
            for name, m in entry.get("models", {}).items():
                c = m.get("cost") or {}
                if "input" in c and "output" in c:
                    for key in (f"{provider}/{name}", name):
                        table.setdefault(key, (c["input"] / 1e6, c["output"] / 1e6))
    else:
        for f in sorted(glob.glob(f"{prices_dir}/portkey-models/pricing/*.json")):
            provider = os.path.basename(f)[:-5]
            for name, m in json.load(open(f)).items():
                pay = (m.get("pricing_config") or {}).get("pay_as_you_go") or {}
                if name != "default" and "request_token" in pay and "response_token" in pay:
                    # Its prices are in cents a token.
                    for key in (f"{provider}/{name}", name):
                        table.setdefault(key, (pay["request_token"]["price"] / 100, pay["response_token"]["price"] / 100))

    def cost(model, i, o):
        a, b = table[model]
        return i * a + o * b
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
