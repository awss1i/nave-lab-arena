#!/usr/bin/env bash
# Starts or stops a prompt tool's service for the prompts race. Usage: clients/prompt_servers.sh up|down NAME
# Each runs from its own compose file and images under a project name of the arena's own, so stopping it removes
# that project's containers and volumes and nothing else. On Docker its containers are kept to the gateway's CPUs.
. ./lib.sh
what=$1 name=$2
keep_cpus() { [ "$(basename "$CONTAINER")" = docker ] && for c in $(docker compose -p "$1" ps -q 2> /dev/null); do docker update --cpuset-cpus "$GATEWAY_CPUS" "$c" > /dev/null 2>&1; done; return 0; }
images() { version "$1" "$(docker compose -p "$1" images 2> /dev/null | awk 'NR > 1 && !seen[$2 ":" $3]++ { printf "%s%s:%s", sep, $2, $3; sep = ", " }')"; }
wait_for() { for _ in $(seq 1 600); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$@")" = 200 ] && return 0; sleep 0.5; done; echo "$name never answered at ${*: -1}" >&2; return 1; }
mkdir -p run
case $name.$what in
  nave.up | nave.down) exit 0;;
  agenta.up)
    # Agenta's own compose file for its released images, with the secrets its example file leaves blank made here.
    # Its API and what the API needs are started, without its web page, sandboxes or front door: the API's port is
    # opened on this machine, so a call skips the front door's hop. Its analytics key is blanked so nothing is sent
    # to its analytics service. The account and API key come from its admin route, and its SDK is installed for the
    # entrant's set-up.
    d="$ARENA_TOOLS/src/agenta"
    [ -d "$d/hosting" ] || { mkdir -p "$ARENA_TOOLS/src" && git clone -q --depth 1 --filter=blob:none --sparse https://github.com/Agenta-AI/agenta "$d" && git -C "$d" sparse-checkout set hosting; } || exit 1
    d="$d/hosting/docker-compose/oss"
    [ -s "$d/.env.arena" ] || python3 -c "
import re, secrets
s = open('$d/env.oss.gh.example').read()
s = re.sub(r'=replace-me', lambda m: '=' + secrets.token_hex(16), s)
s = re.sub(r'^POSTHOG_API_KEY=.*$', 'POSTHOG_API_KEY=', s, flags=re.M)
open('$d/.env.arena', 'w').write(s)"
    printf 'services:\n    api:\n        ports:\n            - "127.0.0.1:8581:8000"\n' > "$d/docker-compose.arena.yml"
    (cd "$d" && ENV_FILE=./.env.arena docker compose -p arena-agenta -f docker-compose.gh.yml -f docker-compose.arena.yml --env-file .env.arena up -d api supertokens > up-arena-agenta.log 2>&1) || { echo "Agenta didn't start: $(tail -3 "$d/up-arena-agenta.log")" >&2; exit 1; }
    keep_cpus arena-agenta; images arena-agenta
    wait_for http://127.0.0.1:8581/health || exit 1
    admin=$(sed -n 's/^AGENTA_AUTH_KEY=//p' "$d/.env.arena")
    curl -s -m 60 -X POST http://127.0.0.1:8581/admin/simple/accounts/ -H "Authorization: Access $admin" -H 'content-type: application/json' \
      -d "{\"options\":{\"create_api_keys\":true,\"return_api_keys\":true},\"accounts\":{\"arena\":{\"user\":{\"email\":\"arena-$(date +%s)@arena.test\"}}}}" \
      | python3 -c "import json, sys; print(json.load(sys.stdin)['accounts']['arena']['api_keys']['key'])" > run/prompt-agenta.key || { echo "Agenta's admin route gave no API key" >&2; exit 1; }
    uv=$(arena_uv)
    [ -x "$ARENA_TOOLS/prompts-agenta/bin/python" ] || { "$uv" venv -q --python 3.12 "$ARENA_TOOLS/prompts-agenta" && "$uv" pip install -q --python "$ARENA_TOOLS/prompts-agenta/bin/python" agenta; } || exit 1
    version agenta-sdk "$("$ARENA_TOOLS/prompts-agenta/bin/python" -c "import importlib.metadata as m; print(m.version('agenta'))" 2> /dev/null)";;
  agenta.down) (cd "$ARENA_TOOLS/src/agenta/hosting/docker-compose/oss" && ENV_FILE=./.env.arena docker compose -p arena-agenta -f docker-compose.gh.yml -f docker-compose.arena.yml --env-file .env.arena down -v > down-arena-agenta.log 2>&1); exit 0;;
  pezzo.up)
    # Pezzo's own compose file and released server image, with the settings files its compose file names written
    # here from its example. Its ports are moved off the ones the arena uses (its ClickHouse would take the
    # stand-in's 9000), and its server answers on 3300. Only its server and what the server needs are started.
    d="$ARENA_TOOLS/src/pezzo/repo"
    if [ ! -d "$d" ]; then
      mkdir -p "$ARENA_TOOLS/src/pezzo" && git clone -q --depth 1 https://github.com/pezzolabs/pezzo "$d" || exit 1
      sed -i 's/"9000:9000"/"19000:9000"/; s/"8123:8123"/"18123:8123"/; s/"9004:9004"/"19004:9004"/; s/"6379:6379"/"16379:6379"/; s/"3567:3567"/"13567:3567"/' "$d/docker-compose.infra.yaml"
      sed -i 's/"3000:3000"/"3300:3000"/' "$d/docker-compose.yaml"
    fi
    printf '%s\n' 'PINO_PRETTIFY="false"' 'DATABASE_URL=postgresql://postgres:postgres@postgres:5432/pezzo' 'SUPERTOKENS_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/postgres' \
      'SUPERTOKENS_CONNECTION_URI="http://supertokens:3567"' 'CONSOLE_HOST="http://pezzo-console:4200"' 'REDIS_URL="redis://redis-stack-server:6379"' \
      'SUPERTOKENS_API_DOMAIN="http://localhost:3300"' 'SUPERTOKENS_WEBSITE_DOMAIN="http://localhost:4200"' > "$d/.env.docker"
    cp "$d/.env.docker" "$d/.env"
    for f in .env.local apps/server/.env apps/server/.env.local apps/console/.env apps/proxy/.env; do : > "$d/$f"; done
    mkdir -p "$d/volumes/clickhouse/data" "$d/volumes/clickhouse/logs"
    # Under podman with SELinux a container reads a folder of this machine only with this label.
    [ "$(basename "$CONTAINER")" = podman ] && chcon -Rt container_file_t "$d/clickhouse" "$d/volumes" 2> /dev/null
    (cd "$d" && docker compose -p arena-pezzo up -d pezzo-server > up-arena-pezzo.log 2>&1) || { echo "Pezzo didn't start: $(tail -3 "$d/up-arena-pezzo.log")" >&2; exit 1; }
    keep_cpus arena-pezzo; images arena-pezzo
    version pezzo "pezzolabs/pezzo at $(git -C "$d" rev-parse --short HEAD), its released server image"
    wait_for http://127.0.0.1:3300/api/healthz;;
  pezzo.down) (cd "$ARENA_TOOLS/src/pezzo/repo" && docker compose -p arena-pezzo down -v > down-arena-pezzo.log 2>&1); exit 0;;
  *) echo "usage: prompt_servers.sh up|down NAME" >&2; exit 2;;
esac
