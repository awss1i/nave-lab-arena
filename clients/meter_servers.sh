#!/usr/bin/env bash
# Starts or stops a metering service for the metering race. Usage: clients/meter_servers.sh up|down NAME
# Each runs from its own compose file as it ships, under a project name of the arena's own.
. ./lib.sh
what=$1 name=$2
compose_up() { # PROJECT [COMPOSE OPTIONS..], from the folder that holds the compose file
  local project=$1; shift
  docker compose -p "$project" "$@" up -d > "up-$project.log" 2>&1 || { echo "$project didn't start: $(grep -i error "up-$project.log" | tail -3)" >&2; return 1; }
  # On Docker its containers are kept to the gateway's CPUs. Rootless podman can't set a running container's CPUs.
  [ "$(basename "$CONTAINER")" = docker ] && for c in $(docker compose -p "$project" ps -q 2> /dev/null); do docker update --cpuset-cpus "$GATEWAY_CPUS" "$c" > /dev/null 2>&1; done
  # The images that ran, for the record.
  version "${project:-$1}" "$(docker compose -p "${project:-$1}" images 2> /dev/null | awk 'NR > 1 && !seen[$2 ":" $3]++ { printf "%s%s:%s", sep, $2, $3; sep = ", " }')"
  return 0
}
wait_for() { for _ in $(seq 1 600); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$@")" = 200 ] && return 0; sleep 0.5; done; echo "$name never answered at ${*: -1}" >&2; return 1; }
case $name.$what in
  nave.up | nave.down) exit 0;;
  openmeter.up)
    # OpenMeter's quickstart: its API, its workers, Kafka, ClickHouse, PostgreSQL and Redis, with the token meter its
    # quickstart config defines. The quickstart config has the sink commit after every event (minCommitCount: 1),
    # which stores about one event a second, so that line is dropped and the sink uses its own default batch. It also
    # gives the sink one second to list Kafka's topics, which a runner's two CPUs miss: the sink then logs "failed to
    # fetch all topics" and stops storing part of the events. That limit can't be longer than the sink's refresh of its topics, which
    # the quickstart also sets to one second, so both lines are dropped for the sink's defaults (15 and 10 seconds).
    d="$ARENA_TOOLS/src/openmeter"
    [ -d "$d/quickstart" ] || { mkdir -p "$ARENA_TOOLS/src" && git clone -q --depth 1 --filter=blob:none --sparse https://github.com/openmeterio/openmeter "$d" && git -C "$d" sparse-checkout set quickstart; } || exit 1
    sed -i '/^  minCommitCount: 1$/d; /^  namespaceRefetch: 1s$/d; /^  namespaceRefetchTimeout: 1s$/d' "$d/quickstart/config.yaml"
    (cd "$d/quickstart" && compose_up arena-openmeter) || exit 1
    version openmeter-settings "its quickstart at $(git -C "$d" rev-parse --short HEAD), with the sink's minCommitCount of 1 and its one-second refresh and limit on listing topics dropped for the sink's defaults (500, and 15 and 10 seconds)"
    wait_for http://127.0.0.1:48888/api/v1/meters;;
  openmeter.down) (cd "$ARENA_TOOLS/src/openmeter/quickstart" && docker compose -p arena-openmeter down -v > down-arena-openmeter.log 2>&1); exit 0;;
  lago.up)
    # Lago from its own compose file, with the settings it has for making the first organisation and its API key at
    # start, and the RSA key its README has you generate.
    d="$ARENA_TOOLS/src/lago"; mkdir -p "$d"
    [ -s "$d/docker-compose.yml" ] || curl -fsSL -m 60 https://raw.githubusercontent.com/getlago/lago/main/docker-compose.yml -o "$d/docker-compose.yml" || exit 1
    if [ ! -s "$d/.env" ]; then
      rm -f "$d/lago-key" "$d/lago-key.pub"; ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -f "$d/lago-key" || exit 1
      printf 'LAGO_RSA_PRIVATE_KEY="%s"\nLAGO_CREATE_ORG=true\nLAGO_ORG_USER_EMAIL=arena@example.com\nLAGO_ORG_USER_PASSWORD=Arena-Race-Pass-2026\nLAGO_ORG_NAME=Arena\nLAGO_ORG_API_KEY=arena-lago-api-key-0000000000000000\nFRONT_PORT=8081\nLAGO_DISABLE_SIGNUP=true\n' "$(base64 -w0 "$d/lago-key")" > "$d/.env"
      rm -f "$d/lago-key" "$d/lago-key.pub"
    fi
    (cd "$d" && compose_up arena-lago) || exit 1
    wait_for -H 'authorization: Bearer arena-lago-api-key-0000000000000000' http://127.0.0.1:3000/api/v1/billable_metrics;;
  lago.down) (cd "$ARENA_TOOLS/src/lago" && docker compose -p arena-lago down -v > down-arena-lago.log 2>&1); exit 0;;
  flexprice.up)
    # Flexprice by its own `make dev-setup`: PostgreSQL, Kafka, ClickHouse, Redis and Temporal from its compose file,
    # its image built from its source, its migrations and seed, then its services. It needs Go and make.
    # Three things in its setup are changed, and each is needed before one event is counted:
    # 1. PostgreSQL's first start runs V5__settings_unique_published_only before the table that file alters exists,
    #    so the file is set aside (the index it adds is on settings, which the race never touches).
    # 2. Its compose file leaves the API writing to the topic `staging_events` while its consumers read `events`,
    #    so the API gets the topic names its own .env.local gives.
    # 3. Its consumer ships limited to 12 events a second, so that limit is lifted.
    d="$ARENA_TOOLS/src/flexprice"
    [ -d "$d" ] || { mkdir -p "$ARENA_TOOLS/src" && git clone -q --depth 1 --branch v2.1.48 https://github.com/flexprice/flexprice "$d"; } || exit 1
    mkdir -p "$ARENA_TOOLS/src/flexprice-set-aside"
    for f in "$d"/migrations/postgres/V5__settings_unique_published_only.*.sql; do [ -e "$f" ] && mv "$f" "$ARENA_TOOLS/src/flexprice-set-aside/"; done
    printf 'services:\n  flexprice-api:\n    environment:\n      - FLEXPRICE_KAFKA_TOPIC=events\n      - FLEXPRICE_KAFKA_TOPIC_LAZY=events_lazy\n  flexprice-consumer:\n    environment:\n      - FLEXPRICE_EVENT_PROCESSING_RATE_LIMIT=1000000\n' > "$d/docker-compose.override.yml"
    (cd "$d" && COMPOSE_PROJECT_NAME=arena-flexprice make dev-setup > dev-setup.log 2>&1) || { echo "Flexprice's dev-setup failed: $(grep -i 'error\|failed' "$d/dev-setup.log" | tail -3)" >&2; exit 1; }
    [ "$(basename "$CONTAINER")" = docker ] && for c in $(docker compose -p arena-flexprice ps -q 2> /dev/null); do docker update --cpuset-cpus "$GATEWAY_CPUS" "$c" > /dev/null 2>&1; done
    version flexprice "flexprice/flexprice v2.1.48 at $(git -C "$d" rev-parse --short HEAD), built here by its make dev-setup, with one migration set aside, the API on the consumers' topic and the 12 events a second limit lifted"
    wait_for -H 'x-api-key: sk_local_flexprice_test_key' http://127.0.0.1:8080/health;;
  flexprice.down) (cd "$ARENA_TOOLS/src/flexprice" && COMPOSE_PROJECT_NAME=arena-flexprice docker compose down -v > down-arena-flexprice.log 2>&1); exit 0;;
  *) echo "usage: meter_servers.sh up|down NAME" >&2; exit 2;;
esac
