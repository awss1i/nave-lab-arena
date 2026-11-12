#!/usr/bin/env bash
# Runs one entrant of one race, pinned to the CPUs its part gets. Usage: ./entrant.sh GROUP NAME [ARGS..]
set -uo pipefail
. ./lib.sh
group=$1 name=$2; shift 2
PY="$ARENA_TOOLS/py/bin/python" LITELLM_PY="$ARENA_TOOLS/litellm/bin/python"
on() { taskset -c "$GATEWAY_CPUS" "$@"; }
# One run of a command as a whole process, from its start to its exit, written as `metric process_ms`.
whole() {
  local t0 t1 out status
  t0=$(date +%s%N)
  out=$("$@" 2> /dev/null); status=$?
  t1=$(date +%s%N)
  echo "$out"
  awk -v ns=$((t1 - t0)) 'BEGIN { printf "metric process_ms=%.2f\n", ns / 1e6 }' >&2
  return $status
}
case "$group.$name" in
  fresh-client.nave) whole taskset -c "$LOAD_CPUS" bin/p018 calls http://127.0.0.1:9000/v1/chat/completions 1;;
  fresh-client.litellm) whole taskset -c "$LOAD_CPUS" "$LITELLM_PY" clients/chat_client.py litellm http://127.0.0.1:9000/v1 1;;
  fresh-client.openai) whole taskset -c "$LOAD_CPUS" "$PY" clients/chat_client.py openai http://127.0.0.1:9000/v1 1;;
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
    # What an engine reports as an image's size differs between engines: some give the layers compressed and some
    # unpacked. A container's files written out as one archive are the same bytes on any of them.
    id=$("$CONTAINER" create "$1") || exit 1
    bytes=$("$CONTAINER" export "$id" | wc -c)
    "$CONTAINER" rm "$id" > /dev/null
    echo measured
    echo "metric image_mb=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1e6 }')" >&2;;
  *) echo "no entrant $group.$name" >&2; exit 2;;
esac
