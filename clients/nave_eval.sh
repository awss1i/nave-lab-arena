#!/usr/bin/env bash
# Runs a suite through Nave's p017 and prints only the lines promptfoo_eval.py prints, so the two compare.
# Usage: nave_eval.sh SUITE.json CONCURRENCY
bin/p017 run "$1" "$2" | grep ' passed$'
