"""Scores prompts with a model picker other than RouteLLM's, on the per-prompt results RouteLLM's repo ships, and
prints the RouteLLM paper's measures and the time for a decision, the same way routellm_bert.py and Nave's p010 do:
prompts ranked by the picker's score, the top share sent to the stronger model, the gap recovered at each share,
APGR as the area under it, and CPT(x) as the smallest share that recovers x of the gap.
Usage: pick_other.py TOOL DIR mmlu|gsm8k [LIMIT]. DIR is a checkout of RouteLLM. LIMIT scores only that many
prompts, spread evenly.

Each picker is used as released, with what it ships, and is asked one thing: how much does this prompt need the
stronger model. A picker that answers with a tier and not a number gives prompts in one tier the same score, and
those are ranked in the order they came, which is what a random order would average to."""
import csv
import glob
import os
import random
import sys
import time
import warnings

warnings.filterwarnings("ignore")
tool, d, which = sys.argv[1], sys.argv[2], sys.argv[3]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 0
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


# Everything a picker's libraries print goes away until the result is ready.
keep = os.dup(1)
os.dup2(os.open(os.devnull, os.O_WRONLY), 1)

if tool == "nadirclaw":
    # NadirClaw's default classifier: sentence embeddings against its two shipped centroids, giving a complexity
    # score from 0 to 1.
    from nadirclaw.classifier import get_binary_classifier

    classifier = get_binary_classifier()
    name = "NadirClaw's binary classifier"

    def score(prompt):
        return float(classifier._analyze_sync(prompt)["complexity_score"])
elif tool == "uncommonroute":
    # UncommonRoute's whole routing decision, with its three local signals, as its proxy runs it for a request.
    # Its complexity number, from 0 to 1, is what picks the tier.
    from uncommon_route.router.api import route

    name = "UncommonRoute"

    def score(prompt):
        return float(route(prompt).complexity)
elif tool == "rorf":
    # Not Diamond's RoRF with a router it released: a random forest over jina-embeddings-v3, trained for GPT-4o
    # against GPT-4o mini. Its probability that the stronger model is the one to call is the score.
    from rorf.controller import Controller

    controller = Controller(router="notdiamond/rorf-jina-gpt4o-gpt4omini", model_a="strong", model_b="weak", threshold=0.5)
    name = "RoRF's released router for GPT-4o and GPT-4o mini"

    def score(prompt):
        return float(controller.predict_proba(prompt)[1])
elif tool == "semantic-router":
    # Aurelio's semantic-router with its local FastEmbed encoder. It routes by examples, so it's given two routes
    # built the way its docs build any route: "strong" from prompts only the stronger model got right and "weak"
    # from prompts the weaker model got right, both from a tenth of MMLU (every tenth prompt), and none from the
    # prompts being scored. The score is how much closer a prompt sits to the "strong" route than to the "weak" one.
    from semantic_router import IndexedRouter, Route
    from semantic_router.encoders import FastEmbedEncoder

    mmlu = []
    for f in sorted(glob.glob(f"{d}/routellm/evals/mmlu/responses/*.csv")):
        with open(f, newline="") as fh:
            reader = csv.reader(fh)
            next(reader)
            mmlu += [(r[0], r[1] == "True", r[2] == "True") for r in reader]
    seen = {r[0] for r in rows}
    train = [r for i, r in enumerate(mmlu) if i % 10 == 0 and (which != "mmlu" or r[0] not in seen)]
    routes = [Route(name="strong", utterances=[p for p, weak, strong in train if strong and not weak]),
              Route(name="weak", utterances=[p for p, weak, strong in train if weak])]
    router = IndexedRouter(encoder=FastEmbedEncoder(name="BAAI/bge-small-en-v1.5"), routes=routes)
    name = f"semantic-router with {len(routes[0].utterances)} and {len(routes[1].utterances)} example prompts"

    def score(prompt):
        found = {c.name: c.confidence or 0.0 for c in router(prompt, limit=2)}
        return found.get("strong", 0.0) - found.get("weak", 0.0)
elif tool == "clawrouter":
    # ClawRouter's local scorer, the 15-dimension weighted score that picks its tier, with its default settings.
    # It's a Node package, so a small Node program beside its node_modules scores every prompt in one process
    # and reports its own time for a decision.
    import json
    import shutil
    import subprocess

    home = os.path.join(os.environ["ARENA_TOOLS"], "pick-clawrouter")
    shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pick_claw.mjs"), home)
    done = json.loads(subprocess.run(["node", "pick_claw.mjs"], cwd=home, input=json.dumps([r[0] for r in rows]), capture_output=True, text=True, check=True).stdout)
    name, claw = "ClawRouter's local scorer", iter(done["scores"])

    def score(prompt):
        return float(next(claw))
elif tool == "llmrouter":
    # LLMRouter's KNN router, trained by its own command on the example data its repo ships: nine models, six of
    # 7B to 9B parameters and three of 49B to 70B, and which of them did best on each of its example queries.
    # Asked to route a prompt, it names one of the nine. The score is the price of the models its neighbours voted for, weighted by their
    # votes, which is highest when it would send the prompt to its largest model.
    import yaml
    from llmrouter.models.knnrouter import KNNRouter
    from llmrouter.utils import get_longformer_embedding, load_model

    repo = os.path.join(os.environ["ARENA_TOOLS"], "src", "llmrouter")
    os.chdir(repo)
    cfg = "configs/model_config_test/knnrouter.yaml"
    router = KNNRouter(yaml_path=cfg)
    saved = yaml.safe_load(open(cfg))["model_path"]["load_model_path"]
    router.knn_model = load_model(next(p for p in (saved, os.path.join("llmrouter", saved)) if os.path.exists(p)))
    import json

    price = {n: float(v["input_price"]) for n, v in json.load(open("data/example_data/llm_candidates/llm_descriptions_with_embeddings.json")).items()}
    name = "LLMRouter's KNN router on its example data"

    def score(prompt):
        votes = router.knn_model.predict_proba([get_longformer_embedding(prompt).numpy()])[0]
        return float(sum(v * price[m] for v, m in zip(votes, router.knn_model.classes_)))
else:
    raise SystemExit(f"no picker {tool}")

if tool == "clawrouter":
    scores = [score(r[0]) for r in rows]
    seconds = done["ns"] * len(rows) / 1e9
else:
    score(rows[0][0])
    t = time.perf_counter()
    scores = [score(r[0]) for r in rows]
    seconds = time.perf_counter() - t
sys.stdout.flush()
os.dup2(keep, 1)
apgr, cpt50, cpt80 = curve(scores)
random.seed(7)
chance = curve([random.random() for _ in rows])[0]
print(f"{name} on {which}: {len(rows)} prompts, APGR {apgr:.3f}, CPT(50%) {cpt50:.2%}, CPT(80%) {cpt80:.2%}, {len(set(scores))} different scores, a random score gives {chance:.3f}")
print(f"metric apgr={apgr:.4f}\nmetric cpt50={cpt50 * 100:.4f}\nmetric cpt80={cpt80 * 100:.4f}\nmetric ns_per_prompt={seconds * 1e9 / len(rows):.0f}\nmetric prompts={len(rows)}", file=sys.stderr)
