# Shared by the arena's scripts. ARENA_TOOLS is where competitors are installed: a folder outside the repo on a
# runner, and the lab's own tools folder when the scripts are tried locally.
export ARENA_TOOLS=${ARENA_TOOLS:-$HOME/arena-tools}
mkdir -p "$ARENA_TOOLS" run results

# The CPUs each part runs on. A GitHub runner has four: the load tool, the stand-in model, and two for the gateway.
# The key every caller sends. Gateways that check keys are given this one, and the stand-in accepts any.
export LLM_KEY=${LLM_KEY:-sk-arena-4f1c9a7e2b8d4c03a6e5f7d9b1c2e3f4}
# How long the load tool waits for a server that isn't listening before it gives up.
export LOAD_WAIT_S=${LOAD_WAIT_S:-15}
export LOAD_CPUS=${LOAD_CPUS:-0} MODEL_CPUS=${MODEL_CPUS:-1} GATEWAY_CPUS=${GATEWAY_CPUS:-2,3}

# Writes a competitor's name and version to the run's list of versions.
version() { printf '%s\t%s\n' "$1" "$2" >> results/versions.tsv; }

# The most memory a server and its children have held, in MB, by its name in run/.
peak_mb() {
  local pid total=0
  pid=$(cat "run/$1.pid" 2>/dev/null) || { echo 0; return; }
  for p in $pid $(pgrep -P "$pid" 2>/dev/null) $(for c in $(pgrep -P "$pid" 2>/dev/null); do pgrep -P "$c" 2>/dev/null; done); do
    kb=$(awk '/VmHWM/ {print $2}' "/proc/$p/status" 2>/dev/null || echo 0)
    total=$((total + ${kb:-0}))
  done
  awk -v kb="$total" 'BEGIN { printf "%.1f\n", kb / 1024 }'
}

# Containers run with docker on a runner and with podman where there's no docker. Each is named arena-NAME, shares
# the host's network, and is pinned to the gateway's CPUs.
# Some machines have a `docker` command that is podman underneath, so the name alone doesn't say which it is.
if command -v docker > /dev/null && ! docker --version 2>&1 | grep -qi podman; then CONTAINER=$(command -v docker); else CONTAINER=$(command -v podman); fi
container_up() { # NAME PORT IMAGE-AND-ARGS..
  local name=$1 port=$2; shift 2
  # The last container of this name has to be gone, with its port, before the next one counts as listening.
  for _ in $(seq 1 300); do
    "$CONTAINER" container inspect "arena-$name" > /dev/null 2>&1 || (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break
    sleep 0.1
  done
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then echo "$name can't start: port $port is already answering" >&2; return 1; fi
  if [ "$(basename "$CONTAINER")" = docker ]; then
    docker run -d --rm --name "arena-$name" --network host --cpuset-cpus "$GATEWAY_CPUS" "$@" > /dev/null
  else
    # PODMAN_USER is how the container's user maps here: the caller's own by default, so mounted folders are
    # writable, and empty for an image that has to start as its own root.
    # shellcheck disable=SC2086
    taskset -c "$GATEWAY_CPUS" podman run -d --rm --name "arena-$name" --network host ${PODMAN_USER---userns=keep-id} "$@" > /dev/null
  fi
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0; sleep "${UP_POLL_S:-0.05}"; done
  echo "$name never listened on $port" >&2; return 1
}
container_down() { for name in "$@"; do "$CONTAINER" kill "arena-$name" > /dev/null 2>&1 || true; done; }
# The memory a container holds now, in MB.
container_mb() {
  "$CONTAINER" stats --no-stream --format '{{.MemUsage}}' "arena-$1" | awk '{ v = $1; if (v ~ /GiB|GB/) { sub(/Gi?B/, "", v); printf "%.1f\n", v * 1024 } else if (v ~ /KiB|kB/) { sub(/[Kk]i?B/, "", v); printf "%.1f\n", v / 1024 } else { sub(/Mi?B/, "", v); printf "%.1f\n", v } }'
}
# The memory a server started by up.sh and its children hold now, in MB.
now_mb() {
  local pid total=0
  pid=$(cat "run/$1.pid" 2>/dev/null) || { echo 0; return; }
  for p in $pid $(pgrep -P "$pid" 2>/dev/null) $(for c in $(pgrep -P "$pid" 2>/dev/null); do pgrep -P "$c" 2>/dev/null; done); do
    kb=$(awk '/VmRSS/ {print $2}' "/proc/$p/status" 2>/dev/null || echo 0)
    total=$((total + ${kb:-0}))
  done
  awk -v kb="$total" 'BEGIN { printf "%.1f\n", kb / 1024 }'
}

# The CPU time a server started by up.sh and its children have used so far, in microseconds.
proc_cpu_us() {
  local pid ticks=0 t hz
  pid=$(cat "run/$1.pid" 2>/dev/null) || { echo 0; return; }
  hz=$(getconf CLK_TCK)
  for p in $pid $(pgrep -P "$pid" 2>/dev/null) $(for c in $(pgrep -P "$pid" 2>/dev/null); do pgrep -P "$c" 2>/dev/null; done); do
    # The fields after the command's name: its own user and system time, and its finished children's.
    t=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{ print $12 + $13 + $14 + $15 }')
    ticks=$((ticks + ${t:-0}))
  done
  echo $((ticks * 1000000 / hz))
}
# The CPU time a container has used so far, in microseconds, from its control group.
container_cpu_us() {
  local pid path
  pid=$("$CONTAINER" inspect -f '{{.State.Pid}}' "arena-$1" 2>/dev/null) || { echo 0; return; }
  path=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)
  awk '/^usage_usec/ { print $2; found = 1 } END { if (!found) print 0 }' "/sys/fs/cgroup$path/cpu.stat" 2>/dev/null || echo 0
}
# Writes one measure taken by a script, outside a race, to the run's list: who, what, the number.
measure() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> results/measures.tsv; }

# A gateway's setup file, setup/NAME.sh, defines NAME_install, NAME_start, NAME_url and NAME_kind (process or
# container), with dashes in NAME written as underscores. It may define the rest, and these stand in when it doesn't.
# NAME_start takes a mode: nothing, "cache" (its own cache on), or "fallback" (the first upstream is the failing
# stand-in on port 9001 and the second is the working one on port 9000).
gw() { # NAME FUNCTION [ARGS..]
  local n=${1//-/_} f=$2; shift 2
  if declare -F "${n}_$f" > /dev/null; then "${n}_$f" "$@"; else "gw_default_$f" "$n" "$@"; fi
}
gw_kind() { local v="${1//-/_}_kind"; echo "${!v:-process}"; }
gw_default_stop() { if [ "$(gw_kind "$1")" = container ]; then container_down "${1//_/-}"; else ./down.sh "${1//_/-}"; fi; }
gw_default_mb() { if [ "$(gw_kind "$1")" = container ]; then container_mb "${1//_/-}"; else now_mb "${1//_/-}"; fi; }
gw_default_cpu_us() { if [ "$(gw_kind "$1")" = container ]; then container_cpu_us "${1//_/-}"; else proc_cpu_us "${1//_/-}"; fi; }
# Extra arguments for the load tool, one a line, such as the headers a gateway routes by.
gw_default_load_args() { :; }
# The kinds of race this gateway can't run, as words, each explained in its setup file.
gw_default_skip() { :; }
# Which features are switched on in this gateway as raced, in a few words, for the record (ruling 39).
gw_default_features() { echo "not stated"; }
# The path of its chat completions and messages endpoints.
gw_default_chat_path() { echo /v1/chat/completions; }
gw_default_messages_path() { echo /v1/messages; }
gw_default_title() { echo "${1//_/-}"; }
# What an install left on disk, in MB: a container's files exported as one archive, or the tool's folder.
gw_default_size_mb() {
  local image="${1}_image" id bytes
  if [ "$(gw_kind "$1")" = container ]; then
    id=$("$CONTAINER" create "${!image}") || { echo 0; return; }
    bytes=$("$CONTAINER" export "$id" | wc -c)
    "$CONTAINER" rm "$id" > /dev/null
    awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1e6 }'
  else
    du -sm "$ARENA_TOOLS/${1//_/-}" 2>/dev/null | cut -f1
  fi
}
# A bind mount of a path in this folder, with the label podman needs under SELinux.
mount_of() { # LOCAL-PATH CONTAINER-PATH
  if [ "$(basename "$CONTAINER")" = podman ]; then echo "$PWD/$1:$2:Z"; else echo "$PWD/$1:$2"; fi
}
# An image's version for the record: its version label when it has one, then when it was made, and its name.
image_version() { # IMAGE
  echo "$("$CONTAINER" image inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.version"}} created {{.Created}}' 2>/dev/null | sed 's/^<no value> //; s/^ //') (image $1)"
}
# The key a caller sends to this gateway: the arena's own, unless the gateway makes its keys itself.
gw_default_key() { echo "$LLM_KEY"; }

# Databases a gateway's docs ask for, each as a container on the gateway's CPUs, since a gateway's database is part
# of what it costs to run. They use ports of their own so they don't meet a database already on the machine.
mysql_up() { # starts MySQL with the database "arena", user root, password arena, on port 3316
  PODMAN_USER= container_up mysql 3316 -e MYSQL_ROOT_PASSWORD=arena -e MYSQL_DATABASE=arena docker.io/library/mysql:8.4 --port=3316 --bind-address=127.0.0.1 --mysqlx=OFF || return 1
  for _ in $(seq 1 600); do "$CONTAINER" exec arena-mysql mysqladmin --protocol=tcp -P 3316 -uroot -parena ping > /dev/null 2>&1 && return 0; sleep 0.2; done
  echo "MySQL never answered" >&2; return 1
}
postgres_up() { # starts PostgreSQL with the database "arena", user arena, password arena, on port 5442
  PODMAN_USER= container_up postgres 5442 -e POSTGRES_USER=arena -e POSTGRES_PASSWORD=arena -e POSTGRES_DB=arena -e PGPORT=5442 docker.io/library/postgres:17 -c listen_addresses=127.0.0.1 || return 1
  for _ in $(seq 1 600); do "$CONTAINER" exec arena-postgres pg_isready -h 127.0.0.1 -p 5442 -U arena > /dev/null 2>&1 && return 0; sleep 0.2; done
  echo "PostgreSQL never answered" >&2; return 1
}
redis_up() { PODMAN_USER= container_up redis 6389 docker.io/library/redis:8 redis-server --port 6389 --bind 127.0.0.1 --save "" --appendonly no; }
# The memory and CPU of several containers together, for a gateway that runs with a database.
containers_mb() { local total=0 m; for c in "$@"; do m=$(container_mb "$c"); total=$(awk -v a="$total" -v b="${m:-0}" 'BEGIN { printf "%.1f", a + b }'); done; echo "$total"; }
containers_cpu_us() { local total=0; for c in "$@"; do total=$((total + $(container_cpu_us "$c"))); done; echo "$total"; }
# The format a gateway takes: "chat" for OpenAI's, or "messages" for one that takes only Anthropic's, whose whole
# job is then sent in Anthropic's format, Nave included.
gw_default_format() { echo chat; }

