"""Runs a suite written for Nave's p017 through an eval framework, against the same stand-in model, and prints the
same lines. Usage: eval_frameworks.py inspect|deepeval|ragas|autoevals SUITE.json CONCURRENCY

Inspect makes the model calls itself. DeepEval, Ragas and autoevals score outputs an application hands them, so here the calls
are made the way their docs do it, with OpenAI's SDK, CONCURRENCY at a time, and the framework does the scoring.
Every framework runs the suite's four kinds of check through a scorer or metric of its own kind."""
import asyncio
import json
import os
import re
import sys
import tempfile
import time

framework, suite_path, conc = sys.argv[1], sys.argv[2], int(sys.argv[3])
suite = json.load(open(suite_path))
target = suite["targets"][0]
base = target["url"].rsplit("/chat/completions", 1)[0]
key = os.environ.get("LLM_KEY", "local")
os.environ.update({"OPENAI_API_KEY": key, "OPENAI_BASE_URL": base, "DEEPEVAL_TELEMETRY_OPT_OUT": "YES", "RAGAS_DO_NOT_TRACK": "true", "INSPECT_LOG_DIR": tempfile.mkdtemp(), "DO_NOT_TRACK": "1"})


def fill(text, variables):
    for k, v in variables.items():
        text = text.replace("{{" + k + "}}", str(v))
    return text


def passes(checks, out):
    for c in checks:
        kind, value = c["type"], c.get("value", "")
        want = not kind.startswith("not-")
        kind = kind.removeprefix("not-")
        got = out.startswith(value) if kind == "starts-with" else value in out if kind == "contains" else re.search(value, out) is not None if kind == "regex" else None
        if got is None:
            raise SystemExit(f"this script doesn't know the check {c['type']}")
        if got != want:
            return False
    return True


cases = [(p["id"], [{"role": m["role"], "content": fill(m["content"], t["vars"])} for m in p["messages"]], t["assert"]) for p in suite["prompts"] for t in suite["tests"]]


async def answers():
    """Every case's answer, CONCURRENCY calls at a time, through OpenAI's SDK."""
    from openai import AsyncOpenAI

    client = AsyncOpenAI(base_url=base, api_key=key, max_retries=0)
    gate = asyncio.Semaphore(conc)

    async def one(messages):
        async with gate:
            r = await client.chat.completions.create(model=target["model"], messages=messages)
            return r.choices[0].message.content

    return await asyncio.gather(*(one(m) for _, m, _ in cases))


t0 = time.perf_counter()
if framework == "inspect":
    from inspect_ai import Task, eval as run_eval
    from inspect_ai.dataset import Sample
    from inspect_ai.model import ChatMessageSystem, ChatMessageUser
    from inspect_ai.scorer import CORRECT, INCORRECT, Score, accuracy, scorer
    from inspect_ai.solver import generate

    @scorer(metrics=[accuracy()])
    def checks():
        async def score(state, target):
            return Score(value=CORRECT if passes(state.metadata["checks"], state.output.completion) else INCORRECT)
        return score

    samples = [Sample(input=[ChatMessageSystem(content=m["content"]) if m["role"] == "system" else ChatMessageUser(content=m["content"]) for m in messages], metadata={"prompt": pid, "checks": c}) for pid, messages, c in cases]
    logs = run_eval(Task(dataset=samples, solver=generate(), scorer=checks()), model=f"openai/{target['model']}", model_base_url=base, max_connections=conc, display="none", log_samples=True)
    results = [(s.metadata["prompt"], next(iter(s.scores.values())).value == CORRECT) for s in logs[0].samples]
elif framework == "deepeval":
    from deepeval import evaluate
    from deepeval.evaluate import AsyncConfig, DisplayConfig
    from deepeval.metrics import BaseMetric
    from deepeval.test_case import LLMTestCase

    class Checks(BaseMetric):
        threshold = 1.0
        async_mode = True

        def measure(self, test_case, *args, **kwargs):
            self.score = 1.0 if passes(json.loads(test_case.additional_metadata["checks"]), test_case.actual_output) else 0.0
            self.success = self.score >= self.threshold
            return self.score

        async def a_measure(self, test_case, *args, **kwargs):
            return self.measure(test_case)

        def is_successful(self):
            return self.success

        @property
        def __name__(self):
            return "Checks"

    outs = asyncio.run(answers())
    tests = [LLMTestCase(input=m[-1]["content"], actual_output=o, name=f"{pid}-{i}", additional_metadata={"prompt": pid, "checks": json.dumps(c)}) for i, ((pid, m, c), o) in enumerate(zip(cases, outs))]
    done = evaluate(test_cases=tests, metrics=[Checks()], async_config=AsyncConfig(max_concurrent=conc), display_config=DisplayConfig(show_indicator=False, print_results=False))
    results = [(r.name.rsplit("-", 1)[0], r.success) for r in done.test_results]
elif framework == "ragas":
    from dataclasses import dataclass, field

    from ragas import EvaluationDataset, evaluate
    from ragas.dataset_schema import SingleTurnSample
    from ragas.metrics.base import MetricType, SingleTurnMetric
    from ragas.run_config import RunConfig

    @dataclass
    class Checks(SingleTurnMetric):
        name: str = "checks"
        _required_columns: dict = field(default_factory=lambda: {MetricType.SINGLE_TURN: {"response", "reference"}})

        def init(self, run_config):
            pass

        async def _single_turn_ascore(self, sample, callbacks):
            return 1.0 if passes(json.loads(sample.reference), sample.response) else 0.0

    outs = asyncio.run(answers())
    data = EvaluationDataset(samples=[SingleTurnSample(user_input=m[-1]["content"], response=o, reference=json.dumps(c)) for (pid, m, c), o in zip(cases, outs)])
    done = evaluate(data, metrics=[Checks()], run_config=RunConfig(max_workers=conc), show_progress=False)
    results = [(pid, s == 1.0) for (pid, _, _), s in zip(cases, done["checks"])]
elif framework == "autoevals":
    from autoevals import Score
    from autoevals.score import Scorer

    class Checks(Scorer):
        def _name(self):
            return "Checks"

        def _run_eval_sync(self, output, expected=None, **kwargs):
            return Score(name="Checks", score=1.0 if passes(expected, output) else 0.0)

        async def _run_eval_async(self, output, expected=None, **kwargs):
            return self._run_eval_sync(output, expected)

    outs = asyncio.run(answers())
    scorer = Checks()

    async def grade():
        return await asyncio.gather(*(scorer.eval_async(output=o, expected=c) for (_, _, c), o in zip(cases, outs)))

    results = [(pid, score.score == 1.0) for (pid, _, _), score in zip(cases, asyncio.run(grade()))]
else:
    raise SystemExit(f"no framework {framework}")
s = time.perf_counter() - t0

tests = len(suite["tests"])
for p in suite["prompts"]:
    print(f"{p['id']} on {target['id']}: {sum(1 for pid, ok in results if pid == p['id'] and ok)} of {tests} passed")
print(f"metric seconds_inside={s:.3f}", file=sys.stderr)
