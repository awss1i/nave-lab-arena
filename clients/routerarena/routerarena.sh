#!/usr/bin/env bash
# Scores Nave's router on RouterArena with RouterArena's own scripts and no call to a provider.
# Usage: clients/routerarena/routerarena.sh REPO VARIANT.., from the arena's folder, where REPO is a clone of
# RouteWorks/RouterArena with its `uv sync` done and its dataset prepared, and a VARIANT is q25, q50, q75, weak or strong.
# The router chooses between two models that the repository holds an answer from for every one of the 8,400 queries:
# deepseek/deepseek-v3.2, the cheaper, and gemini-3-flash-preview. RouterArena's inference step reads those answers
# from a store answers.py builds, and its evaluation step scores them. The answers come first from the two entries
# that send every query to one of those models (chuzom-solo-v32 and llm-router-g3), so the variants weak and strong
# reproduce those entries' scores and show the pipeline here scores as the leaderboard does. The environment the steps run in holds no
# provider key, so a query without a stored answer fails instead of being sent anywhere.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd) arena=$PWD repo=$1; shift
weak=deepseek/deepseek-v3.2 strong=gemini-3-flash-preview
py="$repo/.venv/bin/python"
run() { (cd "$repo" && env -i PATH="$PATH" HOME="$repo/../home" HF_HOME="${HF_HOME:-$repo/../hf}" HF_HUB_OFFLINE=1 DO_NOT_TRACK=1 NAVE_P010="$arena/bin/p010" NAVE_ROUTELLM="$arena/run/pick/RouteLLM" "$py" "$@"); }
mkdir -p "$repo/../home"
cp "$here/nave_router.py" "$repo/router_inference/router/nave_router.py"
grep -q nave_router "$repo/router_inference/router/__init__.py" || echo 'from router_inference.router.nave_router import NaveRouter  # noqa: E402,F401' >> "$repo/router_inference/router/__init__.py"
[ -s "$repo/nave-answers/${strong}.jsonl" ] || "$py" "$here/answers.py" "$repo" "$repo/nave-answers" "$weak=chuzom-solo-v32" "$strong=llm-router-g3"
for v in "$@"; do
  name=nave-$v
  printf '{"pipeline_params": {"router_name": "%s", "router_cls_name": "NaveRouter", "models": ["%s", "%s"]}}\n' "$name" "$weak" "$strong" > "$repo/router_inference/config/$name.json"
  log="$repo/../$name.log"; : > "$log"
  for split in full robustness; do run router_inference/generate_prediction_file.py "$name" "$split" >> "$log" 2>&1; done
  run router_inference/check_config_prediction_files.py "$name" full >> "$log" 2>&1
  run llm_inference/run.py "$name" --split full --cached-results-dir ./nave-answers >> "$log" 2>&1
  run llm_evaluation/run.py "$name" full --cached-results-dir ./nave-answers >> "$log" 2>&1
  run llm_evaluation/run.py "$name" robustness --cached-results-dir ./nave-answers >> "$log" 2>&1 || true
  grep -i "arena score\|accuracy\|cost\|robust\|optimal" "$log" | tail -12 | sed "s/^/$name: /"
done
