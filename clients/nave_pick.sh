#!/usr/bin/env bash
# Nave's router, p010, on RouteLLM's per-prompt results, printing the measures under the names the BERT router's
# script uses, so the two compare. Usage: nave_pick.sh DIR mmlu|gsm8k|gsm8k-untrained
# mmlu and gsm8k train on a tenth of that set and test on the rest. gsm8k-untrained trains on MMLU alone.
dir=$1 which=$2
case $which in mmlu) key=p010_on_mmlu;; gsm8k) key=p010_on_gsm8k;; gsm8k-untrained) key=p010_on_gsm8k_from_mmlu_alone;; esac
bin/p010 eval "$dir" 2> run/pick/p010.err | grep -i "p010 on" | sed -n "$(case $which in mmlu) echo 1;; gsm8k) echo 2;; *) echo 3;; esac)p"
for m in apgr cpt50 cpt80; do echo "metric $m=$(sed -n "s/^metric ${key}_$m=//p" run/pick/p010.err)" >&2; done
bin/p010 speed "$dir" 200000 2>&1 > /dev/null | grep '^metric ns_per_prompt=' >&2
