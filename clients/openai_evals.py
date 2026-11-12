"""Runs a suite written for Nave's p017 through OpenAI's evals, with its own command `oaieval`, against the same
stand-in model, and prints the same lines. Usage: openai_evals.py SUITE.json CONCURRENCY

It writes a registry for the run: a completion function for the stand-in's model, and an eval of the suite whose
class, below in ARENA_EVAL, checks each answer with the suite's four kinds of check. `oaieval` makes the calls."""
import json
import os
import subprocess
import sys
import tempfile

suite_path, conc = sys.argv[1], sys.argv[2]
suite = json.load(open(suite_path))
target = suite["targets"][0]
base = target["url"].rsplit("/chat/completions", 1)[0]
work = tempfile.mkdtemp()
os.makedirs(f"{work}/registry/evals")
os.makedirs(f"{work}/registry/completion_fns")


def fill(text, variables):
    for k, v in variables.items():
        text = text.replace("{{" + k + "}}", str(v))
    return text


with open(f"{work}/samples.jsonl", "w") as f:
    for p in suite["prompts"]:
        for t in suite["tests"]:
            f.write(json.dumps({"input": [{"role": m["role"], "content": fill(m["content"], t["vars"])} for m in p["messages"]], "prompt": p["id"], "checks": t["assert"]}) + "\n")
ARENA_EVAL = '''
import re
import evals
import evals.metrics
from evals.completion_fns.openai import OpenAIChatCompletionFn


def passes(checks, out):
    for c in checks:
        kind, value = c["type"], c.get("value", "")
        want = not kind.startswith("not-")
        kind = kind.removeprefix("not-")
        got = out.startswith(value) if kind == "starts-with" else value in out if kind == "contains" else re.search(value, out) is not None
        if got != want:
            return False
    return True


class Standin(OpenAIChatCompletionFn):
    """Its chat completion function, which doesn't take the registry that oaieval hands a registered one."""

    def __init__(self, model, registry=None, **kwargs):
        super().__init__(model=model, **kwargs)


class Checks(evals.Eval):
    def __init__(self, completion_fns, samples_jsonl, *args, **kwargs):
        super().__init__(completion_fns, *args, **kwargs)
        self.samples_jsonl = samples_jsonl

    def eval_sample(self, sample, rng):
        answer = self.completion_fn(prompt=sample["input"]).get_completions()[0]
        evals.record.record_match(passes(sample["checks"], answer), expected=sample["prompt"], picked=answer)

    def run(self, recorder):
        self.eval_all_samples(recorder, self.get_samples())
        return {"accuracy": evals.metrics.get_accuracy(recorder.get_events("match"))}
'''
open(f"{work}/arena_eval.py", "w").write(ARENA_EVAL)
open(f"{work}/registry/evals/arena.yaml", "w").write(f"arena:\n  id: arena.v0\n  metrics: [accuracy]\narena.v0:\n  class: arena_eval:Checks\n  args:\n    samples_jsonl: {work}/samples.jsonl\n")
open(f"{work}/registry/completion_fns/standin.yaml", "w").write(f"standin:\n  class: arena_eval:Standin\n  args:\n    model: {target['model']}\n")
env = {**os.environ, "OPENAI_API_KEY": os.environ.get("LLM_KEY", "local"), "OPENAI_BASE_URL": base, "EVALS_THREADS": conc, "EVALS_SHOW_EVAL_PROGRESS": "", "PYTHONPATH": work}
oaieval = os.path.join(os.path.dirname(sys.executable), "oaieval")
run = subprocess.run([oaieval, "standin", "arena", "--registry_path", f"{work}/registry", "--record_path", f"{work}/record.jsonl"], env=env, capture_output=True, text=True, cwd=work)
if run.returncode != 0 or not os.path.exists(f"{work}/record.jsonl"):
    print("oaieval gave no record:", run.stdout[-300:], run.stderr[-600:])
    sys.exit(1)
right = {}
for line in open(f"{work}/record.jsonl"):
    event = json.loads(line)
    if event.get("type") == "match":
        right[event["data"]["expected"]] = right.get(event["data"]["expected"], 0) + bool(event["data"]["correct"])
tests = len(suite["tests"])
for p in suite["prompts"]:
    print(f"{p['id']} on {target['id']}: {right.get(p['id'], 0)} of {tests} passed")
