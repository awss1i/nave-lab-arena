#!/usr/bin/env bash
# Starts or stops the stand-in model and every gateway in the race, or runs the load tool against one of them.
# Usage: ./gateways.sh up|down, ./gateways.sh load|cached NAME [load options], ./gateways.sh fresh NAME, ./gateways.sh memory NAME
set -uo pipefail
. ./lib.sh
for s in nave litellm portkey bifrost; do . "setup/$s.sh"; done
GATEWAYS="nave litellm portkey bifrost"
url() { case $1 in nave) echo http://127.0.0.1:4000;; litellm) echo http://127.0.0.1:4100;; portkey) echo http://127.0.0.1:8787;; bifrost) echo http://127.0.0.1:4300;; esac; }
# What the load tool needs to say to each gateway for the same call: Portkey's routing headers, Bifrost's model name.
load() {
  local name=$1; shift
  case $name in
    portkey) taskset -c "$LOAD_CPUS" bin/load "$(url "$name")/v1/chat/completions" --header "x-portkey-provider: openai" --header "x-portkey-custom-host: http://127.0.0.1:9000/v1" "$@";;
    bifrost) taskset -c "$LOAD_CPUS" bin/load "$(url "$name")/v1/chat/completions" --model openai/mock "$@";;
    *) taskset -c "$LOAD_CPUS" bin/load "$(url "$name")/v1/chat/completions" "$@";;
  esac
}
start() { case $1 in litellm) litellm_start 4100 "${2:-}";; nave) nave_start "${2:-}";; *) "$1_start";; esac; }
case $1 in
  up)
    # With caches on, the stand-in writes down every call that reaches it, so a race can show its cache answered.
    [ -n "${CACHE:-}" ] && export STANDIN_LOG=$PWD/run/standin-calls.log
    UP_PORT=9000 ./up.sh standin "$MODEL_CPUS" bin/standin 127.0.0.1:9000 ${STANDIN_ARGS:-}
    for g in ${2:-$GATEWAYS}; do start "$g" "${CACHE:-}" || exit 1; done;;
  down)
    for g in ${2:-$GATEWAYS}; do "${g}_stop"; done
    ./down.sh standin;;
  load) shift; load "$@";;
  cached)
    # The load tool's calls, then how many of them reached the stand-in model.
    shift
    : > run/standin-calls.log
    load "$@"
    echo "metric calls_that_reached_the_model=$(wc -l < run/standin-calls.log)" >&2;;
  fresh)
    # One call through a gateway started for it: the time from the start command to the first right answer.
    export UP_POLL_S=0.002
    t0=$(date +%s%N)
    start "$2" > /dev/null 2>&1
    out=$(load "$2" --calls 1 2>/dev/null)
    t1=$(date +%s%N)
    "$2_stop"
    echo "$out"
    echo "metric start_to_first_answer_ms=$(( (t1 - t0) / 1000000 ))" >&2;;
  memory)
    # 20,000 calls, then what the gateway holds.
    load "$2" --calls 20000 --conns 64 2>/dev/null
    echo "metric memory_mb=$("$2_mb")" >&2;;
esac
