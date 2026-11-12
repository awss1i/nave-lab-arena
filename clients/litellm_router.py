"""Loads a LiteLLM configuration the way LiteLLM's proxy does: the YAML read, then its Router made from the model list.
Usage: litellm_router.py FILE ITERS. Prints what Nave's p019 prints for the same file."""
import os
import sys
import time
import warnings

warnings.filterwarnings("ignore")
os.environ["LITELLM_LOCAL_MODEL_COST_MAP"] = "True"
os.environ["LITELLM_LOG"] = "ERROR"
import yaml  # noqa: E402

import litellm  # noqa: E402

litellm.suppress_debug_info = True
text, iters = open(sys.argv[1]).read(), int(sys.argv[2])
t = time.perf_counter()
for _ in range(iters):
    cfg = yaml.safe_load(text)
    router = litellm.Router(model_list=cfg["model_list"])
ms = (time.perf_counter() - t) * 1e3 / iters
print(f"{len(set(router.get_model_names()))} models")
print(f"metric ms_per_config={ms:.3f}", file=sys.stderr)
