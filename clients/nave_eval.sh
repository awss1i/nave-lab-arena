#!/usr/bin/env bash
# Runs a suite through Nave's p017 and prints only the lines promptfoo_eval.py prints, so the two compare. It's
# timed the way promptfoo is there: one run as a whole process, from its start to its exit.
# Usage: nave_eval.sh SUITE.json CONCURRENCY
err=$(mktemp)
t0=$(date +%s%N)
out=$(bin/p017 run "$1" "$2" 2> "$err"); status=$?
t1=$(date +%s%N)
echo "$out" | grep ' passed$'
# p017's own timer covers less than the whole process, so its figures are kept under other names.
sed -e 's/^metric cases_per_s=/metric cases_per_s_by_its_own_timer=/' -e 's/^metric seconds=/metric seconds_by_its_own_timer=/' "$err" >&2
calls=$(sed -n 's/^metric calls=//p' "$err")
rm -f "$err"
awk -v c="${calls:-0}" -v ns=$((t1 - t0)) 'BEGIN { printf "metric cases_per_s=%.1f\nmetric seconds=%.4f\n", c / (ns / 1e9), ns / 1e9 }' >&2
exit $status
