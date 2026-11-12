#!/usr/bin/env bash
# Starts or stops the stand-in model and the gateways of a race, or runs one entrant's part of a race against one
# of them. Each gateway's own start, stop and settings are in setup/NAME.sh.
# Usage: ./gateways.sh up "NAMES" [MODE], ./gateways.sh down "NAMES", and for one entrant:
#   load NAME [load options]      calls in OpenAI's format
#   quick NAME [load options]     the same, from a client that acknowledges every packet at once
#   messages NAME [load options]  calls in Anthropic's format
#   cached NAME [load options]    the load, then how many calls reached the model
#   rate NAME RATE CALLS CONNS    the load at a fixed rate, with the gateway's CPU time per call
#   quickrate NAME RATE CALLS CONNS  the same, from a client that acknowledges every packet at once
#   open NAME CONNS CALLS         the load against a slow model, with the memory held while the calls are open
#   replay NAME CONNS             a coding agent's session, replayed on each connection
#   fresh NAME                    one call through a gateway started for it
#   memory NAME                   what the gateway holds after 20,000 calls
#   edges NAME                    the checks of clients/edges.py
# NAME "direct" is the stand-in model itself, with no gateway.
set -uo pipefail
. ./lib.sh
for s in setup/*.sh; do . "$s"; done
direct_url() { echo http://127.0.0.1:9000; }
direct_key() { echo "$LLM_KEY"; }
direct_chat_path() { echo /v1/chat/completions; }
direct_messages_path() { echo /v1/messages; }
direct_kind=none
url_of() { gw "$1" url; }
load() { # NAME PATH-KIND [load options]
  local name=$1 kind=$2 path; shift 2
  path=$(gw "$name" "${kind}_path")
  local extra=()
  while IFS= read -r line; do [ -n "$line" ] && extra+=("$line"); done < <(gw "$name" load_args "$kind" "$*")
  LLM_KEY=$(gw "$name" key) taskset -c "$LOAD_CPUS" bin/load "$(url_of "$name")$path" "${extra[@]}" "$@"
}
standin_up() { # NAME PORT [ARGS..]
  local name=$1 port=$2; shift 2
  UP_PORT=$port ./up.sh "$name" "$MODEL_CPUS" bin/standin "127.0.0.1:$port" "$@"
}
# ONE_CPU keeps the gateways to the first of their CPUs, for the race that shows what a second CPU adds.
[ -n "${ONE_CPU:-}" ] && export GATEWAY_CPUS=${GATEWAY_CPUS%%,*}
# The format a job's calls are sent in: OpenAI's, or Anthropic's for a job whose gateway takes nothing else.
fmt() { [ "${ARENA_FORMAT:-chat}" = messages ] && echo messages || echo chat; }
case $1 in
  up)
    # With caches on, the stand-in writes down every call that reaches it, so a race can show its cache answered.
    [ "${3:-}" = cache ] && export STANDIN_LOG=$PWD/run/standin-calls.log
    # For the edge checks it writes down the latest request whole, so what a gateway sent on can be read.
    [ "${3:-}" = edges ] && export STANDIN_BODY=$PWD/run/standin-body.txt
    # shellcheck disable=SC2086
    standin_up standin 9000 ${STANDIN_ARGS:-}
    [ "${3:-}" = fallback ] && standin_up standin-bad 9001 --status 500
    mode=${3:-}; [ "$mode" = edges ] && mode=
    # "own" is the mode of a gateway's own benchmark. Only a gateway whose benchmark needs a setting takes it.
    # run/NAME.mode keeps the race's own mode, edges included, for a gateway that keeps a data folder per mode.
    for g in $2; do [ "$g" = direct ] || { echo "${3:-}" > "run/$g.mode"; gw "$g" start "$mode" || exit 1; }; done;;
  down)
    for g in $2; do [ "$g" = direct ] || gw "$g" stop; done
    ./down.sh standin standin-bad;;
  load) name=$2; shift 2; load "$name" "$(fmt)" "$@";;
  # The same load from a client that acknowledges every packet at once. An ordinary client waits up to 40 ms to
  # acknowledge, and a gateway that sends its answer in two small writes without TCP_NODELAY waits on that.
  quick) name=$2; shift 2; BENCH_QUICKACK=1 load "$name" "$(fmt)" "$@";;
  messages) name=$2; shift 2; load "$name" messages "$@";;
  cached)
    name=$2; shift 2
    : > run/standin-calls.log
    load "$name" "$(fmt)" "$@"
    echo "metric calls_that_reached_the_model=$(wc -l < run/standin-calls.log)" >&2;;
  quickrate) shift; BENCH_QUICKACK=1 exec "$0" rate "$@";;
  rate)
    # The same calls at the same rate for every entrant, so the CPU each one used for them compares.
    before=0; [ "$2" = direct ] || before=$(gw "$2" cpu_us)
    load "$2" "$(fmt)" --rate "$3" --calls "$4" --conns "$5"; status=$?
    after=0; [ "$2" = direct ] || after=$(gw "$2" cpu_us)
    [ "$2" = direct ] || awk -v us=$((after - before)) -v calls="$4" 'BEGIN { printf "metric cpu_us_per_call=%.1f\n", us / calls }' >&2
    exit $status;;
  open)
    # The model takes half a second to answer, so CONNS calls are open at once. The memory is read one second in.
    idle=$(gw "$2" mb)
    load "$2" "$(fmt)" --calls "$4" --conns "$3" > run/open.out 2> run/open.err &
    sleep 1
    held=$(gw "$2" mb)
    wait $!; status=$?
    cat run/open.out; cat run/open.err >&2
    awk -v idle="$idle" -v held="$held" -v conns="$3" 'BEGIN { printf "metric memory_open_mb=%.1f\nmetric kb_per_open_call=%.1f\n", held, (held - idle) * 1024 / conns }' >&2
    exit $status;;
  replay) load "$2" chat --replay run/session.jsonl --conns "$3";;
  fresh)
    # One call through a gateway started for it: the time from the start command to the first right answer.
    export UP_POLL_S=0.002
    : > "run/$2.mode"
    t0=$(date +%s%N)
    gw "$2" start > /dev/null 2>&1
    out=$(load "$2" "$(fmt)" --calls 1 2>/dev/null)
    t1=$(date +%s%N)
    gw "$2" stop
    echo "$out"
    echo "metric start_to_first_answer_ms=$(( (t1 - t0) / 1000000 ))" >&2;;
  memory)
    load "$2" "$(fmt)" --calls 20000 --conns 64 2>/dev/null
    echo "metric memory_mb=$(gw "$2" mb)" >&2;;
  edges)
    name=$2
    args=()
    while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done < <(gw "$name" load_args "$kind" "$*")
    LLM_KEY=$(gw "$name" key) python3 clients/edges.py "$(url_of "$name")" "$(gw "$name" chat_path)" "$(gw "$name" messages_path)" run/standin-body.txt "${args[@]}";;
esac
