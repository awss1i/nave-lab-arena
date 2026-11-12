"""Scores prompts with RouteLLM's BERT router, as released (the checkpoint routellm/bert_gpt4_augmented), on the
per-prompt results RouteLLM's own repo ships, and prints the RouteLLM paper's measures and the time for a decision.
Usage: routellm_bert.py DIR mmlu|gsm8k [LIMIT]. DIR is a checkout of RouteLLM. LIMIT scores only that many prompts,
spread evenly, when the whole set would take too long.

The measures are computed the way Nave's p010 computes them: prompts ranked by score, the top share sent to the
stronger model, the gap recovered at each share, APGR as the area under it, and CPT(x) as the smallest share that
recovers x of the gap. A check on that arithmetic: a router that scores at random comes out near 0.5."""
import csv
import glob
import os
import random
import sys
import time
import warnings

warnings.filterwarnings("ignore")
os.environ.setdefault("OPENAI_API_KEY", "unused")   # RouteLLM builds an OpenAI client when it's imported, and this router never calls it
d, which = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 0
files = sorted(glob.glob(f"{d}/routellm/evals/mmlu/responses/*.csv")) if which == "mmlu" else [f"{d}/routellm/evals/gsm8k/gsm8k_responses.csv"]
rows = []
for f in files:
    with open(f, newline="") as fh:
        reader = csv.reader(fh)
        next(reader)
        rows += [(r[0], r[1] == "True", r[2] == "True") for r in reader]
if limit and limit < len(rows):
    rows = [rows[i * len(rows) // limit] for i in range(limit)]


def curve(scores):
    n = len(rows)
    weak, strong = sum(r[1] for r in rows) / n, sum(r[2] for r in rows) / n
    order = sorted(range(n), key=lambda i: (-scores[i], i))
    right, area, prev, cpt50, cpt80 = sum(r[1] for r in rows), 0.0, 0.0, None, None
    for k, i in enumerate(order):
        right += rows[i][2] - rows[i][1]
        pgr = (right / n - weak) / (strong - weak)
        area += (prev + pgr) / 2 / n
        prev = pgr
        if cpt50 is None and pgr >= 0.5:
            cpt50 = (k + 1) / n
        if cpt80 is None and pgr >= 0.8:
            cpt80 = (k + 1) / n
    return area, cpt50 or float("nan"), cpt80 or float("nan")


from routellm.routers.routers import BERTRouter  # noqa: E402

router = BERTRouter(checkpoint_path="routellm/bert_gpt4_augmented")
router.calculate_strong_win_rate(rows[0][0])
t = time.perf_counter()
scores = [float(router.calculate_strong_win_rate(r[0])) for r in rows]
seconds = time.perf_counter() - t
apgr, cpt50, cpt80 = curve(scores)
random.seed(7)
chance = curve([random.random() for _ in rows])[0]
print(f"RouteLLM's BERT router on {which}: {len(rows)} prompts, APGR {apgr:.3f}, CPT(50%) {cpt50:.2%}, CPT(80%) {cpt80:.2%}, a random score gives {chance:.3f}")
print(f"metric apgr={apgr:.4f}\nmetric cpt50={cpt50 * 100:.4f}\nmetric cpt80={cpt80 * 100:.4f}\nmetric ns_per_prompt={seconds * 1e9 / len(rows):.0f}\nmetric prompts={len(rows)}", file=sys.stderr)
