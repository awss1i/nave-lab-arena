#!/usr/bin/env bash
# Runs one entrant of one race, pinned to the CPUs its part gets. Usage: ./entrant.sh GROUP NAME [ARGS..]
set -uo pipefail
. ./lib.sh
group=$1 name=$2; shift 2
PY="$ARENA_TOOLS/py/bin/python" LITELLM_PY="$ARENA_TOOLS/litellm/bin/python"
on() { taskset -c "$GATEWAY_CPUS" "$@"; }
case "$group.$name" in
  client.nave) taskset -c "$LOAD_CPUS" bin/p018 calls http://127.0.0.1:9000/v1/chat/completions "$@";;
  client.litellm) taskset -c "$LOAD_CPUS" "$LITELLM_PY" clients/chat_client.py litellm http://127.0.0.1:9000/v1 "$@";;
  client.openai) taskset -c "$LOAD_CPUS" "$PY" clients/chat_client.py openai http://127.0.0.1:9000/v1 "$@";;
  template.nave) on bin/p014 file data/prompt.mustache data/prompt-vars.json 20000;;
  template.chevron | template.pystache) on "$PY" clients/mustache_render.py "$name" data/prompt.mustache data/prompt-vars.json 2000;;
  template.mustachejs) on node clients/mustache_render.mjs "$ARENA_TOOLS/node" data/prompt.mustache data/prompt-vars.json 20000;;
  cost.nave) on bin/p009 cost-time run/cost/costs.txt 2000;;
  cost.litellm) on "$LITELLM_PY" clients/litellm_cost.py time run/cost 3;;
  config.nave) on bin/p019 time run/config/large.yaml 20;;
  config.litellm) on "$LITELLM_PY" clients/litellm_router.py run/config/large.yaml 3;;
  eval.nave) on clients/nave_eval.sh run/eval/a.json 16;;
  eval.promptfoo) on "$PY" clients/promptfoo_eval.py "$ARENA_TOOLS/node" run/eval/a.json 16;;
  scan.nave) on python3 clients/scan.py nave run/guard;;
  scan.gitleaks) on python3 clients/scan.py gitleaks run/guard "$ARENA_TOOLS/gitleaks/gitleaks";;
  compress.nave) on "$PY" clients/nave_compress.py "data/compress/$1" 20;;
  compress.headroom) on "$PY" clients/headroom_compress.py "data/compress/$1" 3;;
  image.*)
    # An image's size as its registry would send it isn't known here, so this is its size unpacked on disk.
    echo measured
    echo "metric image_mb=$("$CONTAINER" image inspect "$1" --format '{{.Size}}' | awk '{ printf "%.1f", $1 / 1e6 }')" >&2;;
  *) echo "no entrant $group.$name" >&2; exit 2;;
esac
