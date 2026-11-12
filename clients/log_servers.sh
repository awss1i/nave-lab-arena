#!/usr/bin/env bash
# Starts or stops a log tool's server for the log race. Usage: clients/log_servers.sh up|down NAME
# Each runs the way its own docs start it, with its data and home under run, on the gateway's CPUs.
. ./lib.sh
what=$1 name=$2 d="$PWD/run/log-$2"
wait_for() { for _ in $(seq 1 600); do curl -fsS -m 2 -o /dev/null "$1" 2> /dev/null && return 0; sleep 0.5; done; echo "$name never answered at $1: $(tail -3 "$d/serve.log" 2> /dev/null)" >&2; return 1; }
# A server starts as the leader of a process group of its own, so stopping it stops its workers too, by the group's
# id and nothing else.
# Starts a server in the background as the leader of a new session, on the gateway's CPUs, and writes down its id,
# which is also its process group's.
start() { setsid bash -c 'echo $$ > "$0/pid"; exec taskset -c "$1" "${@:2}" > "$0/serve.log" 2>&1' "$d" "$GATEWAY_CPUS" "$@" < /dev/null > /dev/null 2>&1 & }
stop_pid() { [ -f "$d/pid" ] && kill -- "-$(cat "$d/pid")" 2> /dev/null; rm -f "$d/pid"; return 0; }
case $name.$what in
  nave.up | nave.down) exit 0;;
  phoenix.up)
    rm -rf "$d"; mkdir -p "$d"
    PHOENIX_WORKING_DIR="$d" PHOENIX_HOST=127.0.0.1 PHOENIX_PORT=6006 HOME="$d" PHOENIX_TELEMETRY_ENABLED=false start "$ARENA_TOOLS/log-phoenix/bin/phoenix" serve
    wait_for http://127.0.0.1:6006/healthz;;
  phoenix.down) stop_pid;;
  mlflow.up)
    rm -rf "$d"; mkdir -p "$d"
    (cd "$d" && HOME="$d" MLFLOW_DISABLE_TELEMETRY=true DO_NOT_TRACK=true start "$ARENA_TOOLS/log-mlflow/bin/mlflow" server --host 127.0.0.1 --port 5001 --backend-store-uri sqlite:///mlflow.db --workers 2)
    wait_for http://127.0.0.1:5001/health;;
  mlflow.down) stop_pid;;
  *) echo "usage: log_servers.sh up|down NAME" >&2; exit 2;;
esac
