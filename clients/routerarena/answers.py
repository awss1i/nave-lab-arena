"""Builds a store of answers RouterArena's own inference step can read, from answers its repository already holds.
Usage: answers.py REPO OUT MODEL[=ENTRY]..
Every leaderboard entry's prediction file in REPO carries, for each query, the model it chose and that model's
answer with its token counts. For each MODEL this collects that model's answer to every query from those files and
writes OUT/MODEL.jsonl in the format of the repository's cached_results, so a router that chooses MODEL is scored
on the answer MODEL gave when a leaderboard entry called it, with no call to a provider. Where several entries
hold an answer to the same query, ENTRY's is used when it has one (an entry that sends every query to MODEL, so
choosing MODEL every time reproduces that entry's row on the leaderboard), and otherwise the first file's by name.
It prints how many of the queries each model has and how many came from ENTRY."""
import glob
import json
import os
import sys

repo, out = sys.argv[1], sys.argv[2]
first = dict((a.split("=", 1) + [""])[:2] for a in sys.argv[3:])
models = list(first)
os.makedirs(out, exist_ok=True)
queries = [row["global index"] for row in json.load(open(f"{repo}/dataset/router_data.json"))]
found = {m: {} for m in models}
paths = sorted(glob.glob(f"{repo}/router_inference/predictions/*.json"), key=lambda p: (os.path.basename(p)[:-5] not in first.values(), p))
for path in paths:
    name = os.path.basename(path)[:-5]
    if name.endswith("-robustness") or name.startswith("nave-"):
        continue
    for row in json.load(open(path)):
        got, model = row.get("generated_result"), row.get("prediction")
        if model in found and isinstance(got, dict) and str(got.get("success")) == "True" and got.get("generated_answer"):
            found[model].setdefault(row.get("global index") or row.get("global_index"), (name, row, got))
for model, answers in found.items():
    with open(f"{out}/{model.replace('/', '_')}.jsonl", "w", encoding="utf-8") as f:
        for q in queries:
            if q in answers:
                name, row, got = answers[q]
                f.write(json.dumps({"global_index": q, "question": row.get("prompt", ""), "llm_selected": model, "generated_answer": got["generated_answer"], "token_usage": got.get("token_usage", {}),
                                    "success": True, "provider": got.get("provider", "unknown"), "error": None, "taken_from": name}, ensure_ascii=False) + "\n")
    print(f"{model}: answers to {sum(q in answers for q in queries)} of {len(queries)} queries, {sum(q in answers and answers[q][0] == first[model] for q in queries)} of them from {first[model] or 'no entry in particular'}")
