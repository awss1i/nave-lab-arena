#!/usr/bin/env bash
# Starts or stops an MCP gateway in front of the stand-in MCP server, for the MCP race.
# Usage: clients/mcp_gateways.sh up|down|url|key|revision NAME
# The stand-in MCP server is on port 9100 with eight tools, started by the race. Each gateway is set up the way its
# own docs say, with its home under the arena's tools or under run, and `url`, `key` and `revision` say how the load
# tool reaches it: Nave's speaks revision 2026-07-28, the others an earlier one.
. ./lib.sh
what=$1 name=$2
case $name.$what in
  standin.up) UP_PORT=9100 ./up.sh mcpstandin "$MODEL_CPUS" bin/mcpstandin 127.0.0.1:9100 --name standin --tools 8;;
  standin.down) ./down.sh mcpstandin;;
  nave.up) UP_PORT=4100 ./up.sh nave-mcp "$GATEWAY_CPUS" bin/p012 --listen 127.0.0.1:4100 --server standin=http://127.0.0.1:9100/mcp --cpus "$GATEWAY_CPUS";;
  nave.down) ./down.sh nave-mcp;;
  nave.url) echo http://127.0.0.1:4100/mcp;;
  nave.key) echo local;;
  nave.revision) echo;;
  contextforge.up)
    # IBM's ContextForge from PyPI, with secrets from its own script, SQLite as it ships, its guard against local
    # addresses told to allow them, and its rate limiting off, since at its defaults it locks a caller out for 15
    # minutes after a hundred calls in one. The stand-in is registered as a gateway and a virtual server holds its tools.
    d="$ARENA_TOOLS/mcp-contextforge"; w="$PWD/run/mcp-contextforge"; rm -rf "$w"; mkdir -p "$w/home"
    (cd "$w" || exit 1
     HOME="$w/home" "$d/bin/python" -m mcpgateway.scripts.init_secrets --force > /dev/null 2>&1
     set -a; . ./.env.secrets; set +a
     export HOME="$w/home" MCPGATEWAY_UI_ENABLED=false MCPGATEWAY_ADMIN_API_ENABLED=true PLATFORM_ADMIN_EMAIL=admin@example.com DATABASE_URL=sqlite:///./mcp.db LOG_LEVEL=ERROR SSRF_ALLOW_LOCALHOST=true \
       RATE_LIMITING_ENABLED=false TOOL_RATE_LIMIT=100000000
     nohup taskset -c "$GATEWAY_CPUS" "$d/bin/mcpgateway" --host 127.0.0.1 --port 4444 > serve.log 2>&1 &
     echo $! > pid
     for _ in $(seq 1 300); do curl -fsS -m 2 -o /dev/null http://127.0.0.1:4444/health 2>/dev/null && break; sleep 0.5; done
     "$d/bin/python" -m mcpgateway.utils.create_jwt_token --username admin@example.com --exp 10080 --secret "$JWT_SECRET_KEY" 2>/dev/null | tail -1 > token)
    token=$(cat "$w/token"); api() { curl -fsS -m 60 -H "Authorization: Bearer $token" -H 'content-type: application/json' "$@"; }
    # Its first start makes the admin account after its health check answers, so the token is tried until it's taken.
    for _ in $(seq 1 120); do api -o /dev/null http://127.0.0.1:4444/tools 2> /dev/null && break; sleep 0.5; done
    api -o /dev/null -X POST -d '{"name":"standin","url":"http://127.0.0.1:9100/mcp","transport":"STREAMABLEHTTP"}' http://127.0.0.1:4444/gateways || { echo "ContextForge didn't take the stand-in: $(tail -2 "$w/serve.log")" >&2; exit 1; }
    tools=$(api http://127.0.0.1:4444/tools | python3 -c 'import json, sys; print(json.dumps([t["id"] for t in json.load(sys.stdin)]))')
    api -X POST -d '{"server":{"name":"arena","description":"the stand-in","associated_tools":'"$tools"'}}' http://127.0.0.1:4444/servers | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])' > "$w/server" || exit 1;;
  contextforge.down) [ -f run/mcp-contextforge/pid ] && kill "$(cat run/mcp-contextforge/pid)" 2> /dev/null; rm -f run/mcp-contextforge/pid; exit 0;;
  contextforge.url) echo "http://127.0.0.1:4444/servers/$(cat run/mcp-contextforge/server)/mcp";;
  contextforge.key) cat run/mcp-contextforge/token;;
  contextforge.revision) echo 2025-06-18;;
  *) echo "usage: mcp_gateways.sh up|down|url|key|revision NAME" >&2; exit 2;;
esac
