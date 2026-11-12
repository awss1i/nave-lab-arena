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
  mcphub.up)
    # MCPHub from its own official image, with the stand-in in the settings file its README has you write before the
    # first start, local addresses allowed, its bearer key set and its web page off.
    podman unshare rm -rf run/mcphub-data 2> /dev/null || sudo rm -rf run/mcphub-data 2> /dev/null || rm -rf run/mcphub-data
    mkdir -p run/mcphub-data && chmod 777 run/mcphub-data
    printf '{"mcpServers":{"standin":{"type":"streamable-http","url":"http://127.0.0.1:9100/mcp"}},"systemConfig":{"network":{"allowedCidrs":["127.0.0.0/8"]},"routing":{"enableGlobalRoute":true,"enableGroupNameRoute":true,"enableBearerAuth":true,"bearerAuthKey":"arena-mcp-key"}}}\n' > run/mcphub-data/mcp_settings.json
    PODMAN_USER= container_up mcphub 3000 -e ADMIN_PASSWORD=Arena-Race-Pass-2026 -e DISABLE_WEB=true -v "$(mount_of run/mcphub-data /app/data)" docker.io/samanhappy/mcphub:latest || exit 1
    # It connects to the stand-in after its port answers, so its list is waited for.
    for _ in $(seq 1 120); do
      MCP_KEY=arena-mcp-key bin/mcpload http://127.0.0.1:3000/mcp --what list --revision 2025-06-18 --servers standin --expect 8 --calls 1 > /dev/null 2>&1 && exit 0
      sleep 0.5
    done
    echo "MCPHub never listed the stand-in's tools" >&2; exit 1;;
  mcphub.down) container_down mcphub;;
  mcphub.url) echo http://127.0.0.1:3000/mcp;;
  mcphub.key) echo arena-mcp-key;;
  mcphub.revision) echo 2025-06-18;;
  metamcp.up)
    # MetaMCP from its own official image, on PostgreSQL as its compose file runs it. It's set up through the API its
    # web page uses: the first account, the stand-in as an MCP server, a namespace holding it, an endpoint on that
    # namespace with its API key check on, and a key.
    a=http://localhost:12008
    postgres_up || exit 1
    PODMAN_USER= container_up metamcp 12008 -e NODE_ENV=production -e LOG_LEVEL=errors-only -e POSTGRES_HOST=127.0.0.1 -e POSTGRES_PORT=5442 -e POSTGRES_USER=arena -e POSTGRES_PASSWORD=arena -e POSTGRES_DB=arena \
      -e DATABASE_URL=postgresql://arena:arena@127.0.0.1:5442/arena -e APP_URL=$a -e NEXT_PUBLIC_APP_URL=$a -e BETTER_AUTH_SECRET=arena-auth-secret-arena-auth-secret-0000 \
      -e TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL=false -e BOOTSTRAP_ENABLE=false ghcr.io/metatool-ai/metamcp:latest || exit 1
    for _ in $(seq 1 240); do
      curl -fsS -m 20 -o /dev/null -H 'content-type: application/json' -H "origin: $a" -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026","name":"Arena"}' "$a/api/auth/sign-up/email" 2> /dev/null && break
      sleep 0.5
    done
    cookie=$(curl -fsS -m 20 -D - -o /dev/null -H 'content-type: application/json' -H "origin: $a" -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026"}' "$a/api/auth/sign-in/email" | sed -n 's/^set-cookie: \(better-auth.session_token=[^;]*\).*/\1/ip' | tr -d '\r')
    [ -n "$cookie" ] || { echo "MetaMCP didn't sign the first account in" >&2; exit 1; }
    call() { curl -fsS -m 60 -H "cookie: $cookie" -H "origin: $a" -H 'content-type: application/json' -d "$2" "$a/trpc/frontend/frontend.$1"; }
    field() { python3 -c 'import json, sys; d = json.load(sys.stdin)["result"]["data"]; print((d.get("data") or d)[sys.argv[1]])' "$1"; }
    server=$(call mcpServers.create '{"name":"standin","type":"STREAMABLE_HTTP","url":"http://127.0.0.1:9100/mcp"}' | field uuid) || exit 1
    space=$(call namespaces.create '{"name":"arena","description":"the stand-in","mcpServerUuids":["'"$server"'"]}' | field uuid) || exit 1
    call endpoints.create '{"name":"arena","description":"the stand-in","namespaceUuid":"'"$space"'","enableApiKeyAuth":true,"enableClientMaxRate":false,"enableMaxRate":false,"useQueryParamAuth":false,"createMcpServer":false}' > /dev/null || exit 1
    call apiKeys.create '{"name":"arena"}' | field key > run/metamcp.key || exit 1
    for _ in $(seq 1 120); do
      MCP_KEY=$(cat run/metamcp.key) bin/mcpload http://127.0.0.1:12008/metamcp/arena/mcp --what list --revision 2025-06-18 --servers standin --expect 8 --calls 1 > /dev/null 2>&1 && exit 0
      sleep 0.5
    done
    echo "MetaMCP never listed the stand-in's tools" >&2; exit 1;;
  metamcp.down) container_down metamcp postgres;;
  metamcp.url) echo http://127.0.0.1:12008/metamcp/arena/mcp;;
  metamcp.key) cat run/metamcp.key;;
  metamcp.revision) echo 2025-06-18;;
  docker-mcp.up)
    # Docker's MCP gateway from its own official image, with a catalog file that names the stand-in as a remote
    # server, as its remote_mcp example does. Static mode keeps it off the Docker socket, its setting for local
    # development allows a plain-HTTP remote, its bearer token is set, and its log of every call is off.
    mkdir -p run/docker-mcp
    printf 'registry:\n  standin:\n    remote:\n      url: "http://127.0.0.1:9100/mcp"\n      transport_type: http\n' > run/docker-mcp/catalog.yaml
    PODMAN_USER= container_up docker-mcp 8811 -e MCP_GATEWAY_AUTH_TOKEN=arena-mcp-key -e DOCKER_MCP_ALLOW_INSECURE_REMOTE_URLS=1 -v "$(mount_of run/docker-mcp/catalog.yaml /root/.docker/mcp/catalogs/arena.yaml)" \
      docker.io/docker/mcp-gateway:latest --catalog=/root/.docker/mcp/catalogs/arena.yaml --servers=standin --transport=streaming --port=8811 --host=127.0.0.1 --static --log-calls=false || exit 1
    for _ in $(seq 1 120); do
      MCP_KEY=arena-mcp-key bin/mcpload http://127.0.0.1:8811/mcp --what list --revision 2025-06-18 --servers standin --expect 8 --calls 1 > /dev/null 2>&1 && exit 0
      sleep 0.25
    done
    echo "Docker's MCP gateway never listed the stand-in's tools" >&2; exit 1;;
  docker-mcp.down) container_down docker-mcp;;
  docker-mcp.url) echo http://127.0.0.1:8811/mcp;;
  docker-mcp.key) echo arena-mcp-key;;
  docker-mcp.revision) echo 2025-06-18;;
  ms-mcp.up) exec clients/ms_mcp_gateway.sh up;;
  ms-mcp.down) exit 0;;
  ms-mcp.url) echo http://127.0.0.1:8790/adapters/standin/mcp;;
  ms-mcp.key) echo local;;
  ms-mcp.revision) echo;;
  *) echo "usage: mcp_gateways.sh up|down|url|key|revision NAME" >&2; exit 2;;
esac
