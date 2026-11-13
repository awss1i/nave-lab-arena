#!/usr/bin/env bash
# Starts or stops a log tool's server for the log race. Usage: clients/log_servers.sh up|down NAME
# Each runs the way its own docs start it, with its data and home under run, on the gateway's CPUs.
. ./lib.sh
what=$1 name=$2 d="$PWD/run/log-$2"
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
  *) echo "usage: log_servers.sh up|down NAME" >&2; exit 2;;
esac
