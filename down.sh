#!/usr/bin/env bash
# Stops servers started by up.sh, by their recorded PIDs, with the children they started, and returns only once
# they're gone, so the next start never finds the last one still holding its port. Usage: ./down.sh NAME..
for name in "$@"; do
  [ -f "run/$name.pid" ] || continue
  pid=$(cat "run/$name.pid")
  children=$(pgrep -P "$pid" 2>/dev/null)
  all="$pid $children $(for c in $children; do pgrep -P "$c" 2>/dev/null; done)"
  # The server first, so one that restarts its workers doesn't start new ones while they're being stopped.
  kill "$pid" 2>/dev/null || true
  left=$all
  for _ in $(seq 1 100); do
    left=$(for p in $all; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
    [ -z "$left" ] && break
    sleep 0.1
  done
  for p in $left; do kill -9 "$p" 2>/dev/null || true; done
  rm -f "run/$name.pid"
done
