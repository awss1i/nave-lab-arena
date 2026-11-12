#!/usr/bin/env bash
# A quick check of one gateway's setup against the stand-in, before its job runs on a runner: plain calls, streamed
# calls and calls in Anthropic's format, each with every answer checked. Usage: ./smoke.sh NAME [MODE]
. ./lib.sh
for s in setup/*.sh; do . "$s"; done
name=$1 mode=${2:-}
skip=" $(gw "$name" skip) "
./gateways.sh up "$name" "$mode" || { echo "$name didn't start"; ./gateways.sh down "$name"; exit 1; }
show() { head -4 | tr '\n' ' '; echo; }
ARENA_FORMAT=$(gw "$name" format); export ARENA_FORMAT
[ "$ARENA_FORMAT" = messages ] && skip="$skip messages " && echo "every call is in Anthropic's format"
printf 'plain     '; ./gateways.sh load "$name" --calls 200 --conns 8 2>&1 | show
printf 'streamed  '; ./gateways.sh load "$name" --calls 100 --conns 8 --stream 2>&1 | show
case $skip in *" messages "*) echo "messages  skipped";; *) printf 'messages  '; ./gateways.sh messages "$name" --calls 50 --conns 4 2>&1 | show;; esac
echo "memory    $(gw "$name" mb) MB, cpu so far $(gw "$name" cpu_us) us"
./gateways.sh down "$name"
declare -F "${name//-/_}_clean" > /dev/null && "${name//-/_}_clean"

