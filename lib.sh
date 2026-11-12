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
  if [ "$(basename "$CONTAINER")" = docker ]; then
    docker run -d --rm --name "arena-$name" --network host --cpuset-cpus "$GATEWAY_CPUS" "$@" > /dev/null
  else
    taskset -c "$GATEWAY_CPUS" podman run -d --rm --name "arena-$name" --network host --userns=keep-id "$@" > /dev/null
  fi
  for _ in $(seq 1 600); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0; sleep 0.05; done
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
