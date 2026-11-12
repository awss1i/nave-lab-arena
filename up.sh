#!/usr/bin/env bash
# Starts a server in the background on the given CPUs and records its PID, so it is stopped by PID and nothing else is.
# Usage: ./up.sh NAME CPUS CMD ARGS.. It waits until PORT answers when
# UP_PORT is set.
set -euo pipefail
name=$1; cpus=$2; shift 2
mkdir -p run
if [ -f "run/$name.pid" ] && kill -0 "$(cat "run/$name.pid")" 2>/dev/null; then kill "$(cat "run/$name.pid")"; sleep 0.1; fi
# A port that already answers belongs to something else, and waiting on it would take that for this server.
if [ -n "${UP_PORT:-}" ]; then
  for _ in $(seq 1 300); do
    (exec 3<>"/dev/tcp/127.0.0.1/$UP_PORT") 2>/dev/null || break
    sleep 0.1
  done
  if (exec 3<>"/dev/tcp/127.0.0.1/$UP_PORT") 2>/dev/null; then echo "$name can't start: port $UP_PORT is already answering" >&2; exit 1; fi
fi
# The log keeps every start, so a start that failed earlier in a run can still be read at the end of it.
echo "--- $name started $(date -u +%H:%M:%S)" >> "run/$name.log"
nohup taskset -c "$cpus" "$@" >> "run/$name.log" 2>&1 &
echo $! > "run/$name.pid"
if [ -n "${UP_PORT:-}" ]; then
  for _ in $(seq 1 3000); do
    (exec 3<>"/dev/tcp/127.0.0.1/$UP_PORT") 2>/dev/null && exit 0
    kill -0 "$(cat "run/$name.pid")" 2>/dev/null || { echo "$name stopped: $(tail -3 "run/$name.log")" >&2; exit 1; }
    sleep 0.1
  done
  echo "$name never listened on $UP_PORT" >&2; exit 1
fi
