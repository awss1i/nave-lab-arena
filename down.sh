#!/usr/bin/env bash
# Stops servers started by up.sh, by their recorded PIDs, with the children they started. Usage: ./down.sh NAME..
for name in "$@"; do
  if [ -f "run/$name.pid" ]; then
    pid=$(cat "run/$name.pid")
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      for grandchild in $(pgrep -P "$child" 2>/dev/null); do kill "$grandchild" 2>/dev/null || true; done
      kill "$child" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
    rm -f "run/$name.pid"
  fi
done
