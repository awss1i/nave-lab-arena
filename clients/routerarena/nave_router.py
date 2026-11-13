"""Nave's router as a RouterArena router. It's P010: hashed word and character features and a linear model, trained on
RouteLLM's public MMLU and GSM8K results and on nothing of RouterArena's, as RouterArena's rules require. P010 scores
how likely the cheaper model is to fall short, and a query whose score is over a threshold goes to the stronger
model. The threshold is a score that a set share of RouteLLM prompts P010 didn't train on fall under, so it's
fixed before any RouterArena query is seen.

The router's name picks the variant: nave-q25, nave-q50 and nave-q75 use the score a quarter, a half and three
quarters of those prompts fall under. nave-weak and nave-strong send every query to one model, to check this
pipeline against the leaderboard's own single-model entries.

P010 runs as one process for the whole run (NAVE_P010 is the binary, NAVE_ROUTELLM the folder of RouteLLM's results)."""
import os
import subprocess

from router_inference.router.base_router import BaseRouter


class NaveRouter(BaseRouter):
    def __init__(self, router_name: str):
        super().__init__(router_name)
        self.weak, self.strong = self.models[0], self.models[1]
        self.variant = router_name.split("-", 1)[1]
        self.threshold = None
        if self.variant.startswith("q"):
            self.p010 = subprocess.Popen([os.environ["NAVE_P010"], "scores", os.environ["NAVE_ROUTELLM"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8")
            held = self.p010.stdout.readline().split()
            assert held[0] == "held-out", held
            self.threshold = float(held[1 + ["q25", "q50", "q75"].index(self.variant)])

    def _get_prediction(self, query: str) -> str:
        if self.threshold is None:
            return self.weak if self.variant == "weak" else self.strong
        self.p010.stdin.write(query.replace("\\", "\\\\").replace("\r", " ").replace("\n", "\\n") + "\n")
        self.p010.stdin.flush()
        return self.strong if float(self.p010.stdout.readline()) > self.threshold else self.weak
