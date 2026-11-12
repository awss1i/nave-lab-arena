#!/usr/bin/env bash
# Starts or stops ModelCache's demo service for the cache race. Usage: clients/cache_servers.sh up|down modelcache
# It runs from its repo's folder at its latest tagged release, as its README starts it, with its home under the
# arena's tools, on the client's and the gateway's CPUs since the client waits on it.
d="$ARENA_TOOLS/cache-modelcache"
case $2.$1 in
  modelcache.up)
    mkdir -p "$d/home"
    (cd "$ARENA_TOOLS/src/modelcache" && rm -rf data/*.db data/*.index 2> /dev/null
     HOME="$d/home" HF_HOME="$ARENA_TOOLS/models" DO_NOT_TRACK=1 nohup taskset -c "$GATEWAY_CPUS" "$d/bin/python" flask4modelcache_demo.py > "$d/serve.log" 2>&1 & echo $! > "$d/pid")
    for _ in $(seq 1 300); do curl -fsS -m 2 -o /dev/null http://127.0.0.1:5000/welcome 2>/dev/null && exit 0; sleep 0.5; done
    echo "ModelCache's service never answered: $(tail -2 "$d/serve.log")" >&2; exit 1;;
  modelcache.down) [ -f "$d/pid" ] && kill "$(cat "$d/pid")" 2> /dev/null; rm -f "$d/pid"; exit 0;;
  *) echo "usage: cache_servers.sh up|down modelcache" >&2; exit 2;;
esac
