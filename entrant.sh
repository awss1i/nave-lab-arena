#!/usr/bin/env bash
# Runs one entrant of one race, pinned to the CPUs its part gets. Usage: ./entrant.sh GROUP NAME [ARGS..]
set -uo pipefail
. ./lib.sh
group=$1 name=$2; shift 2
PY="$ARENA_TOOLS/py/bin/python" LITELLM_PY="$ARENA_TOOLS/litellm/bin/python"
# Runs a command whose libraries write a lot to stderr: only its metric lines are passed on, and when it fails,
# the last lines of what it wrote, so a failure on a runner can be read from the record.
quiet() {
  local err rc
  err=$(mktemp)
  "$@" 2> "$err"; rc=$?
  grep '^metric ' "$err" >&2
  [ "$rc" -ne 0 ] && tail -8 "$err" >&2
  rm -f "$err"
  return "$rc"
}
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
  fresh-client.*) whole "$0" client "$name" 1;;
  client.nave) taskset -c "$LOAD_CPUS" bin/p018 calls http://127.0.0.1:9000/v1/chat/completions "$@";;
  client.litellm) taskset -c "$LOAD_CPUS" "$LITELLM_PY" clients/chat_client.py litellm http://127.0.0.1:9000/v1 "$@";;
  client.openai | client.aisuite | client.any-llm | client.langchain | client.llm) taskset -c "$LOAD_CPUS" "$PY" clients/chat_client.py "$name" http://127.0.0.1:9000/v1 "$@";;
  client.ruby_llm) GEM_HOME="$ARENA_TOOLS/gems" GEM_PATH="$ARENA_TOOLS/gems" taskset -c "$LOAD_CPUS" ruby clients/chat_client.rb http://127.0.0.1:9000/v1 "$@";;
  client.genai | client.rig | client.graniet-llm)
    bin=$name; [ "$name" = graniet-llm ] && bin=llm
    taskset -c "$LOAD_CPUS" "$ARENA_TOOLS/rust-clients/release/${bin}_client" http://127.0.0.1:9000/v1 "$@";;
  # The JavaScript libraries are imported by name, so the script runs from beside their node_modules folder.
  client.vercel-ai | client.tokenjs | client.tanstack-ai | client.pi-ai) cp clients/chat_client.mjs "$ARENA_TOOLS/node/" && taskset -c "$LOAD_CPUS" node "$ARENA_TOOLS/node/chat_client.mjs" "$name" http://127.0.0.1:9000/v1 "$@";;
  template.nave) on bin/p014 file data/prompt.mustache data/prompt-vars.json 20000;;
  template.chevron | template.pystache) on "$PY" clients/mustache_render.py "$name" data/prompt.mustache data/prompt-vars.json 2000;;
  template.mustachejs) on node clients/mustache_render.mjs "$ARENA_TOOLS/node" data/prompt.mustache data/prompt-vars.json 20000;;
  cost.nave) on bin/p009 cost-time run/cost/costs.txt 2000;;
  cost.litellm) on "$LITELLM_PY" clients/litellm_cost.py time run/cost 3;;
  cost.tokencost | cost.genai-prices | cost.models.dev | cost.portkey-models) on "$PY" clients/cost_libs.py "$name" run/cost 3;;
  config.nave) on bin/p019 time run/config/large.yaml 20;;
  config.litellm) on "$LITELLM_PY" clients/litellm_router.py run/config/large.yaml 3;;
  eval.nave) on clients/nave_eval.sh run/eval/a.json 16;;
  eval.promptfoo) on "$PY" clients/promptfoo_eval.py "$ARENA_TOOLS/node" run/eval/a.json 16;;
  eval.inspect | eval.deepeval | eval.ragas | eval.autoevals | eval.openai-evals)
    # Timed the way the others are: one run as a whole process, from its start to its exit. It runs from run/,
    # since these frameworks write caches into the folder they're started in.
    pkg=$name; [ "$name" = inspect ] && pkg=inspect-ai
    script="../clients/eval_frameworks.py $name"; [ "$name" = openai-evals ] && script=../clients/openai_evals.py
    cases=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(len(d["prompts"]) * len(d["tests"]))' run/eval/a.json)
    t0=$(date +%s%N)
    # shellcheck disable=SC2086
    out=$(cd run && on "$ARENA_TOOLS/eval-$pkg/bin/python" $script eval/a.json 16 2> "eval/$name.err"); status=$?
    t1=$(date +%s%N)
    echo "$out" | grep ' passed$'
    grep '^metric ' "run/eval/$name.err" >&2
    [ "$status" = 0 ] || { echo "$out" | tail -3 >&2; tail -5 "run/eval/$name.err" >&2; }
    awk -v c="$cases" -v ns=$((t1 - t0)) 'BEGIN { printf "metric cases_per_s=%.1f\nmetric seconds=%.4f\n", c / (ns / 1e9), ns / 1e9 }' >&2
    exit "$status";;
  scan.nave) on python3 clients/scan.py nave run/guard;;
  scan.gitleaks) on python3 clients/scan.py gitleaks run/guard "$ARENA_TOOLS/gitleaks/gitleaks";;
  pii.nave) on python3 clients/pii.py nave run/guard;;
  pii.presidio) quiet on "$ARENA_TOOLS/guard-presidio/bin/python" clients/pii.py presidio run/guard;;
  pii.guardrails-ai) (export HOME="$ARENA_TOOLS/guard-guardrails-ai/home"; quiet on "$ARENA_TOOLS/guard-guardrails-ai/bin/python" clients/pii.py guardrails-ai run/guard);;
  pii.nemo) quiet on "$ARENA_TOOLS/guard-nemo/bin/python" clients/pii.py nemo run/guard;;
  pii.llm-guard) (export HF_HOME="$ARENA_TOOLS/models" DO_NOT_TRACK=1; quiet on "$ARENA_TOOLS/guard-llm-guard/bin/python" clients/pii.py llm-guard run/guard);;
  compress.nave) on "$PY" clients/nave_compress.py "data/compress/$1" 20;;
  compress.headroom) on "$PY" clients/headroom_compress.py "data/compress/$1" 3;;
  cachelib.nave) (export STANDIN_CALLS="$PWD/run/standin-calls.log"; quiet taskset -c "$LOAD_CPUS" "$ARENA_TOOLS/cache-gptcache/bin/python" clients/cache_libs.py nave 500);;
  cachelib.modelcache) (export STANDIN_CALLS="$PWD/run/standin-calls.log"; quiet taskset -c "$LOAD_CPUS" "$ARENA_TOOLS/cache-gptcache/bin/python" clients/cache_libs.py modelcache 500);;
  cachelib.*)
    # A library's cache runs inside the client, so the client gets the gateway's CPUs as well as its own.
    (export STANDIN_CALLS="$PWD/run/standin-calls.log" HF_HOME="$ARENA_TOOLS/models" CACHE_DIR="$PWD/run/cache-$name" DO_NOT_TRACK=1; quiet taskset -c "$LOAD_CPUS,$GATEWAY_CPUS" "$ARENA_TOOLS/cache-$name/bin/python" clients/cache_libs.py "$name" 500);;
  mcp.*)
    # A list or a call through an MCP gateway, at the revision the gateway speaks.
    revision=$(clients/mcp_gateways.sh revision "$name"); what=$1; shift
    MCP_KEY=$(clients/mcp_gateways.sh key "$name") taskset -c "$LOAD_CPUS" bin/mcpload "$(clients/mcp_gateways.sh url "$name")" --what "$what" $([ "$name" = ms-mcp ] && echo "--bare standin" || echo "--servers standin") --expect 8 ${revision:+--revision "$revision"} "$@";;
  prompt.nave) on python3 clients/prompt_tools.py nave 2000;;
  prompt.agenta) [ -x "$ARENA_TOOLS/prompts-agenta/bin/python" ] && [ -s run/prompt-agenta.key ] || { echo "Agenta's start didn't finish: $(grep -v '^+' run/prompt-agenta.up.log | tail -4 | cut -c1-300) / last steps: $(grep '^+' run/prompt-agenta.up.log | tail -3 | cut -c1-200)" >&2; exit 1; }
    (export HOME="$PWD/run/prompt-home" DO_NOT_TRACK=1; mkdir -p "$HOME"; quiet taskset -c "$LOAD_CPUS" "$ARENA_TOOLS/prompts-agenta/bin/python" clients/prompt_tools.py agenta 2000);;
  prompt.*) quiet taskset -c "$LOAD_CPUS" python3 clients/prompt_tools.py "$name" 2000;;
  meter.nave) on python3 clients/meter_tools.py nave 20000;;
  meter.*) quiet taskset -c "$LOAD_CPUS" python3 clients/meter_tools.py "$name" "${1:-20000}";;
  log.nave) on python3 clients/log_tools.py nave 20000;;
  logsdk.nave) on python3 clients/log_sdk.py nave 2000;;
  logsdk.*) (export HOME="$PWD/run/log-driver-home"; mkdir -p "$HOME"; quiet taskset -c "$LOAD_CPUS,$GATEWAY_CPUS" "$ARENA_TOOLS/log-$name/bin/python" clients/log_sdk.py "$name" 2000);;
  log.*) calls=${1:-20000}; (export HOME="$PWD/run/log-driver-home"; mkdir -p "$HOME"; quiet taskset -c "$LOAD_CPUS" "$ARENA_TOOLS/log-driver/bin/python" clients/log_tools.py "$name" "$calls");;
  pick.nave) on clients/nave_pick.sh run/pick/RouteLLM "$1";;
  pick.other) tool=$1; shift; py="$ARENA_TOOLS/pick-$tool/bin/python"; [ -x "$py" ] || py=python3
    (export HOME="$ARENA_TOOLS/pick-$tool/home" HF_HOME="$ARENA_TOOLS/models" FASTEMBED_CACHE_PATH="$ARENA_TOOLS/models/fastembed" DO_NOT_TRACK=1; mkdir -p "$HOME"; quiet on "$py" clients/pick_other.py "$tool" "$PWD/run/pick/RouteLLM" "$@");;
  pick.routellm) (export HF_HOME="$ARENA_TOOLS/models" DO_NOT_TRACK=1; quiet on "$ARENA_TOOLS/pick-routellm/bin/python" clients/routellm_bert.py run/pick/RouteLLM "$@");;
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
