#!/usr/bin/env bash
# Starts or stops a log tool's server for the log race. Usage: clients/log_servers.sh up|down NAME
# Each runs the way its own docs start it, with its data and home under run, on the gateway's CPUs.
. ./lib.sh
what=$1 name=$2 d="$PWD/run/log-$2"
# What a start says is kept, so an entrant whose server didn't come up can say why.
mkdir -p run; [ "$what" = up ] && exec 2> "run/log-$name.up.log"
wait_for() { for _ in $(seq 1 600); do curl -fsS -m 2 -o /dev/null "$1" 2> /dev/null && return 0; sleep 0.5; done; echo "$name never answered at $1: $(tail -3 "$d/serve.log" 2> /dev/null)" >&2; return 1; }
# A server starts as the leader of a process group of its own, so stopping it stops its workers too, by the group's
# id and nothing else.
# A tool that ships as a compose file runs from that file under a project name of the arena's own, so stopping it
# removes that project's containers and volumes and nothing else. On Docker its containers are kept to the gateway's
# CPUs. Rootless podman can't set a running container's CPUs, and a run here is only a check.
compose_up() { # PROJECT [COMPOSE OPTIONS..], from the folder that holds the compose file
  local project=$1; shift
  docker compose -p "$project" "$@" up -d > "up-$project.log" 2>&1 || { echo "$project didn't start: $(tail -3 "up-$project.log")" >&2; return 1; }
  set -- "$project"
  [ "$(basename "$CONTAINER")" = docker ] && for c in $(docker compose -p "$1" ps -q 2> /dev/null); do docker update --cpuset-cpus "$GATEWAY_CPUS" "$c" > /dev/null 2>&1; done
  # The images that ran, for the record.
  version "${project:-$1}" "$(docker compose -p "${project:-$1}" images 2> /dev/null | awk 'NR > 1 && !seen[$2 ":" $3]++ { printf "%s%s:%s", sep, $2, $3; sep = ", " }')"
  return 0
}
compose_down() { (cd "$2" && docker compose -p "$1" "${@:3}" down -v > "down-$1.log" 2>&1); return 0; } # PROJECT FOLDER [COMPOSE OPTIONS..]
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
  langfuse.up)
    # Langfuse from its own compose file as it is, with the settings it has for a setup without the web page: an
    # organisation, a project and its two keys. Its telemetry is off. Its six containers are kept to the gateway's CPUs.
    mkdir -p "$ARENA_TOOLS/src/langfuse"
    [ -s "$ARENA_TOOLS/src/langfuse/docker-compose.yml" ] || curl -fsSL -m 60 https://raw.githubusercontent.com/langfuse/langfuse/main/docker-compose.yml -o "$ARENA_TOOLS/src/langfuse/docker-compose.yml" || exit 1
    (cd "$ARENA_TOOLS/src/langfuse" && TELEMETRY_ENABLED=false LANGFUSE_INIT_ORG_ID=arena LANGFUSE_INIT_ORG_NAME=Arena LANGFUSE_INIT_PROJECT_ID=arena LANGFUSE_INIT_PROJECT_NAME=arena LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-arena \
       LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-arena LANGFUSE_INIT_USER_EMAIL=arena@example.com LANGFUSE_INIT_USER_NAME=Arena LANGFUSE_INIT_USER_PASSWORD=Arena-Race-Pass-2026 compose_up arena-langfuse) || exit 1
    d="$ARENA_TOOLS/src/langfuse"; wait_for http://127.0.0.1:3000/api/public/health;;
  langfuse.down) compose_down arena-langfuse "$ARENA_TOOLS/src/langfuse";;
  opik.up)
    # Opik from its own compose file with its "opik" profile, as its README starts the whole of it, with its usage
    # reports off.
    d="$ARENA_TOOLS/src/opik/repo/deployment/docker-compose"
    [ -d "$d" ] || { mkdir -p "$ARENA_TOOLS/src/opik" && git clone -q --depth 1 --filter=blob:none --sparse https://github.com/comet-ml/opik "$ARENA_TOOLS/src/opik/repo" && git -C "$ARENA_TOOLS/src/opik/repo" sparse-checkout set deployment/docker-compose; } || exit 1
    (cd "$d" && OPIK_USAGE_REPORT_ENABLED=false compose_up arena-opik --profile opik) || exit 1
    # Its backend runs its migrations before it answers, which takes minutes on two CPUs, so it gets three waits.
    wait_for http://127.0.0.1:5173/api/v1/private/projects 2> /dev/null || wait_for http://127.0.0.1:5173/api/v1/private/projects 2> /dev/null || wait_for http://127.0.0.1:5173/api/v1/private/projects
    (cd "$d" && docker compose -p arena-opik ps -a > "$OLDPWD/run/compose-opik-at-start.log" 2>&1); true;;
  opik.down) compose_down arena-opik "$ARENA_TOOLS/src/opik/repo/deployment/docker-compose" --profile opik;;
  langwatch.up)
    # LangWatch by its own server command from npm, which fetches and runs its app, PostgreSQL, Redis and
    # ClickHouse under its home folder. It runs in a Node container as the caller's user, since its PostgreSQL
    # won't start as root. Its sign-up goes through an emailed link, so the account is written into its PostgreSQL
    # the way its own tests seed one (a verified user and its password account). Everything after that goes
    # through its API: sign in, make the organisation, a project and an API key bound to the project.
    d="$ARENA_TOOLS/log-langwatch"; mkdir -p "$d"
    b=http://localhost:5560 stamp=$(date +%s) user=()
    # A stop that didn't let its PostgreSQL finish leaves its lock files, and no server of it can be running here.
    rm -f "$d/.langwatch/data/postgres/postmaster.pid" "$d/.langwatch/run/.s.PGSQL.6560.lock" "$d/.langwatch/run/.s.PGSQL.6560"
    # Its PostgreSQL needs a user the container knows by name. Under podman that's the caller, mapped in. Under
    # Docker it's the image's own user "node", and the folder is opened to it.
    if [ "$(basename "$CONTAINER")" = podman ]; then user=(--userns=keep-id --user "$(id -u):$(id -g)"); else user=(--user node); chmod 777 "$d"; fi
    "$CONTAINER" run -d --rm --name arena-langwatch --network host "${user[@]}" -e HOME=/work -e DO_NOT_TRACK=1 -e DISABLE_USAGE_STATS=true \
      -v "$d:/work$([ "$(basename "$CONTAINER")" = podman ] && echo :Z)" -w /work docker.io/library/node:24 sh -c 'exec npx -y @langwatch/server start --yes --no-open > /work/start.log 2>&1' > /dev/null || exit 1
    [ "$(basename "$CONTAINER")" = docker ] && docker update --cpuset-cpus "$GATEWAY_CPUS" arena-langwatch > /dev/null 2>&1
    # Its first start downloads its parts, which takes minutes.
    wait_for "$b/api/health" 2> /dev/null || wait_for "$b/api/health" 2> /dev/null || wait_for "$b/api/health" || { cp "$d/start.log" run/log-langwatch-start.log 2> /dev/null; grep -v "^npm notice" "$d/start.log" | tail -6 >&2; exit 1; }
    version langwatch "$(sed -n 's/^v\([0-9][0-9.]*\) .*/\1/p' "$d/start.log" | head -1), by npx @langwatch/server in docker.io/library/node:24"
    sql() { "$CONTAINER" exec -e LD_LIBRARY_PATH=/work/.langwatch/bin/postgres/lib arena-langwatch /work/.langwatch/bin/postgres/bin/psql -h 127.0.0.1 -p 6560 -U langwatch -d langwatch_db -At -c "$1"; }
    hash=$("$(arena_uv)" run -q --with bcrypt python -c "import bcrypt; print(bcrypt.hashpw(b'Arena-pass-12345', bcrypt.gensalt(10)).decode())") || exit 1
    sql "begin; insert into langwatch_db.\"User\" (id, name, email, \"emailVerified\", \"updatedAt\") values ('arena-user-$stamp', 'Arena', 'arena-$stamp@arena.test', true, now()); insert into langwatch_db.\"Account\" (id, \"userId\", type, provider, issuer, \"providerAccountId\", password, \"updatedAt\") values ('arena-account-$stamp', 'arena-user-$stamp', 'credentials', 'credential', 'local:credential', 'arena-user-$stamp', '$hash', now()); commit;" > /dev/null || exit 1
    rm -f "$d/cookies"
    api() { curl -fsS -m 120 -b "$d/cookies" -c "$d/cookies" -H 'content-type: application/json' -H "origin: $b" "$@"; }
    api -o /dev/null -d "{\"email\":\"arena-$stamp@arena.test\",\"password\":\"Arena-pass-12345\"}" "$b/api/auth/sign-in/email" || { echo "LangWatch didn't sign the account in" >&2; exit 1; }
    ids=$(api -d '{"orgName":"Arena '"$stamp"'","primaryIntent":"LLM_OPS","signUpData":{"terms":true,"usage":"Company"}}' "$b/api/trpc/organization.createAndAssign" | python3 -c 'import json, sys; d = json.load(sys.stdin)["result"]["data"]; print(d["organization"]["id"], d["team"]["id"])') || exit 1
    org=${ids% *} team=${ids#* }
    api -o /dev/null -d "{\"organizationId\":\"$org\",\"teamId\":\"$team\",\"name\":\"Arena\",\"language\":\"python\",\"framework\":\"openai\"}" "$b/api/trpc/project.create" || exit 1
    project=$(sql "select id from langwatch_db.\"Project\" where \"teamId\" = '$team' limit 1")
    api -d "{\"organizationId\":\"$org\",\"name\":\"arena\",\"keyType\":\"personal\",\"permissionMode\":\"all\",\"bindings\":[{\"role\":\"ADMIN\",\"scopeType\":\"PROJECT\",\"scopeId\":\"$project\"}]}" "$b/api/trpc/apiKey.create" \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["data"]["token"], end="")' > run/log-langwatch.key || { echo "LangWatch didn't make an API key" >&2; exit 1; };;
  langwatch.down) "$CONTAINER" stop -t 30 arena-langwatch > /dev/null 2>&1; exit 0;;
  latitude.up)
    # Latitude by its single-host guide: its deploy files from its repo, its released images, and one settings file
    # made from its example with the production values the example itself names, the bundled object store's
    # settings switched on, fresh secrets, and its deployment heartbeat off. It ships with no mail service and signs
    # users in by an emailed link, so a mail catcher joins the stack and the link is read from it. The organisation
    # is made through its sign-in service, the first API key through the server function its web page calls (the
    # API makes keys only for a caller that already has one), and the project through its API with that key.
    d="$ARENA_TOOLS/src/latitude"; mkdir -p "$d/docker/seaweedfs" "$d/docker/clickhouse"
    base=https://raw.githubusercontent.com/latitude-dev/latitude-llm/development
    for f in docker-stack.yml .env.example docker/init-db.sh docker/seaweedfs/init.sh docker/clickhouse/storage.xml; do
      [ -s "$d/$f" ] || curl -fsSL -m 60 "$base/$f" -o "$d/$f" || { echo "Latitude's $f didn't download" >&2; exit 1; }
    done
    chmod +x "$d/docker/init-db.sh" "$d/docker/seaweedfs/init.sh"
    [ "$(basename "$CONTAINER")" = podman ] && chcon -Rt container_file_t "$d/docker" 2> /dev/null
    python3 - "$d" <<'PY' || exit 1
import re, secrets, sys
d = sys.argv[1]
out, pending = [], None
for line in open(f"{d}/.env.example").read().split("\n"):
    hint = re.match(r'#\s*Change to "?([^"]+?)"? for production', line)
    if hint:
        pending = hint.group(1)
    elif pending and re.match(r"^[A-Z_]+=", line):
        key = line.split("=", 1)[0]
        # The public addresses stay this machine's.
        if not key.endswith(("_URL", "_ORIGINS")) or "CLICKHOUSE" in key or "DATABASE" in key:
            line = f"{key}={pending}"
        pending = None
    elif line.strip() and not line.startswith("#"):
        pending = None
    line = re.sub(r"^# (LAT_STORAGE_S3_[A-Z_]*=)", r"\1", line)
    if line.startswith(("LAT_MASTER_ENCRYPTION_KEY=", "LAT_BETTER_AUTH_SECRET=")):
        line = line.split("=", 1)[0] + "=" + secrets.token_hex(32)
    if not line.startswith("LAT_MAILPIT_"):
        out.append(line)
out += ["LAT_SMTP_HOST=mailpit", "LAT_SMTP_PORT=1025", "LAT_SMTP_USER=arena", "LAT_SMTP_PASS=arena", "LAT_SMTP_FROM=noreply@arena.test", "LAT_OSS_TELEMETRY_ENABLED=false", ""]
open(f"{d}/.env.production", "w").write("\n".join(out))
PY
    printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.24\n    environment:\n      MP_SMTP_AUTH_ACCEPT_ANY: "1"\n      MP_SMTP_AUTH_ALLOW_INSECURE: "1"\n    ports:\n      - "127.0.0.1:8025:8025"\n' > "$d/docker-compose.arena.yml"
    (cd "$d" && compose_up arena-latitude --env-file .env.production -f docker-stack.yml -f docker-compose.arena.yml) || exit 1
    w=http://localhost:3000
    wait_for "$w/api/health" && wait_for http://localhost:3001/health && wait_for http://localhost:3002/health || exit 1
    rm -f "$d/cookies"; mail="arena-$(date +%s)@arena.test"
    web() { curl -fsS -m 60 -b "$d/cookies" -c "$d/cookies" -H 'content-type: application/json' -H "origin: $w" "$@"; }
    web -o /dev/null -d "{\"email\":\"$mail\",\"name\":\"Arena\",\"callbackURL\":\"/\"}" "$w/api/auth/sign-in/magic-link" || { echo "Latitude didn't take the sign-in request" >&2; exit 1; }
    token=
    for _ in $(seq 1 120); do
      token=$(curl -fsS -m 10 http://127.0.0.1:8025/api/v1/messages | python3 -c "
import json, re, sys, urllib.request
for m in json.load(sys.stdin)['messages']:
    if m['To'][0]['Address'] == '$mail':
        text = json.load(urllib.request.urlopen('http://127.0.0.1:8025/api/v1/message/' + m['ID']))['Text']
        print(re.search(r'#token=([^\s\"<>&]+)', text).group(1))
        break" 2> /dev/null)
      [ -n "$token" ] && break; sleep 0.5
    done
    [ -n "$token" ] || { echo "Latitude's sign-in mail never reached the catcher" >&2; exit 1; }
    web -o /dev/null "$w/api/auth/magic-link/verify?token=$token" || exit 1
    org=$(web -d "{\"name\":\"Arena\",\"slug\":\"arena-$(date +%s)\"}" "$w/api/auth/organization/create" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])') || exit 1
    web -o /dev/null -d "{\"organizationId\":\"$org\"}" "$w/api/auth/organization/set-active" || exit 1
    # The server function's id and its request body, in the web app's own serialisation, are read from the image.
    fn=$("$CONTAINER" exec arena-latitude-web-1 sh -c 'grep -h -A1 "createApiKey_createServerFn_handler = createServerRpc" /app/apps/web/.output/server/_ssr/api-keys.functions-*.mjs | sed -n "s/.*id: \"\([0-9a-f]*\)\".*/\1/p" | head -1')
    body=$("$CONTAINER" exec arena-latitude-web-1 node -e 'const p = require("child_process").execSync("find /app/node_modules/.pnpm -maxdepth 1 -name \"seroval@*\" | head -1").toString().trim(); console.log(JSON.stringify(require(p + "/node_modules/seroval").toJSON({ data: { name: "arena" }, context: {} })))')
    [ -n "$fn" ] && [ -n "$body" ] || { echo "Latitude's key function wasn't found in its web image" >&2; exit 1; }
    web -H 'x-tsr-serverFn: true' -H 'accept: application/json' -d "$body" "$w/_serverFn/$fn" | python3 -c '
import json, sys
def find(node):
    if isinstance(node, dict):
        p = node.get("p")
        if p and "token" in p.get("k", []):
            return dict(zip(p["k"], p["v"]))["token"]["s"]
        node = list(node.values())
    if isinstance(node, list):
        for v in node:
            found = find(v)
            if found:
                return found
print(find(json.load(sys.stdin)) or "", end="")' > run/log-latitude.key
    [ -s run/log-latitude.key ] || { echo "Latitude didn't make an API key" >&2; exit 1; }
    curl -fsS -m 60 -o /dev/null -H "Authorization: Bearer $(cat run/log-latitude.key)" -H 'content-type: application/json' -d '{"name":"Arena"}' http://localhost:3001/v1/projects || { echo "Latitude didn't make the project" >&2; exit 1; };;
  latitude.down) (cd "$ARENA_TOOLS/src/latitude" && docker compose -p arena-latitude --env-file .env.production -f docker-stack.yml -f docker-compose.arena.yml down -v > down-arena-latitude.log 2>&1); exit 0;;
  agentops.up)
    # AgentOps's recording path and nothing else of it: the collector it builds from its repo (its own image of
    # the OpenTelemetry collector with its token check and its cost rules) and ClickHouse with its migrations. Its
    # API, dashboard and the Supabase project they need aren't started. The API's part in recording is to sign the
    # token a caller sends with its spans, so the entrant signs that token itself, with the same secret and claims.
    d="$ARENA_TOOLS/src/agentops"
    [ -d "$d/app/opentelemetry-collector" ] || { mkdir -p "$ARENA_TOOLS/src" && git clone -q --depth 1 --filter=blob:none --sparse https://github.com/AgentOps-AI/agentops "$d" && git -C "$d" sparse-checkout set app/opentelemetry-collector app/clickhouse; } || exit 1
    cat > "$d/app/docker-compose.arena.yml" <<'YAML'
# The arena's own file: AgentOps's collector, built from its folder, and ClickHouse as its own compose file runs it,
# with ClickHouse's ports kept off the ones the arena uses.
services:
  otelcollector:
    build:
      context: ./opentelemetry-collector
    environment:
      - CLICKHOUSE_ENDPOINT=http://clickhouse:8123
      - CLICKHOUSE_USERNAME=default
      - CLICKHOUSE_PASSWORD=password
      - CLICKHOUSE_DATABASE=otel_2
      - LOGS_TABLE_NAME=otel_logs
      - TRACES_TABLE_NAME=otel_traces
      - CLICKHOUSE_TTL=12h
      - CLICKHOUSE_TIMEOUT=10s
      - JWT_SECRET=super-secret-jwt-token-with-at-least-32-characters-long
    ports:
      - "127.0.0.1:4318:4318"
    depends_on:
      - clickhouse
  clickhouse:
    image: clickhouse/clickhouse-server:24.12
    environment:
      - CLICKHOUSE_DB=otel_2
      - CLICKHOUSE_USER=default
      - CLICKHOUSE_PASSWORD=password
    ports:
      - "127.0.0.1:18124:8123"
YAML
    (cd "$d/app" && docker compose -p arena-agentops -f docker-compose.arena.yml up -d clickhouse > up-arena-agentops.log 2>&1) || { echo "AgentOps's ClickHouse didn't start: $(tail -3 "$d/app/up-arena-agentops.log")" >&2; exit 1; }
    wait_for http://127.0.0.1:18124/ping || exit 1
    # Its README's local steps apply its first migration, which makes the tables. Its later ones add a price
    # dictionary that signs in to ClickHouse with no password and so fails beside the password its compose file sets.
    "$CONTAINER" exec -i arena-agentops-clickhouse-1 clickhouse-client --user default --password password --multiquery < "$d/app/clickhouse/migrations/0000_init.sql" > /dev/null || { echo "AgentOps's first migration failed" >&2; exit 1; }
    (cd "$d/app" && compose_up arena-agentops -f docker-compose.arena.yml) || exit 1
    version agentops "AgentOps-AI/agentops at $(git -C "$d" rev-parse --short HEAD), its collector built from app/opentelemetry-collector"
    for _ in $(seq 1 600); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:4318/v1/traces)" = 401 ] && exit 0; sleep 0.5; done
    echo "AgentOps's collector never answered" >&2; exit 1;;
  agentops.down) (cd "$ARENA_TOOLS/src/agentops/app" && docker compose -p arena-agentops -f docker-compose.arena.yml down -v > down-arena-agentops.log 2>&1); exit 0;;
  *) echo "usage: log_servers.sh up|down NAME" >&2; exit 2;;
esac
