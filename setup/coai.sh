# CoAI, from its own official image, with MySQL and Redis as its README runs it. Its channels live in its config
# file, so the stand-in is written there as a channel of OpenAI's type before the start, and the key is the first
# account's own, read through its API. The databases run on the gateway's CPUs and count as CoAI's.
coai_kind=container
coai_image=docker.io/programzmh/chatnio:latest
coai_title() { echo CoAI; }
coai_install() {
  "$CONTAINER" pull -q "$coai_image" > /dev/null
  version coai "$(image_version "$coai_image")"
}
coai_url() { echo http://127.0.0.1:8094; }
coai_chat_path() { echo /api/v1/chat/completions; }
coai_start() { # MODE
  local b=http://127.0.0.1:8094/api token
  "$CONTAINER" container inspect arena-mysql > /dev/null 2>&1 || mysql_up || return 1
  "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
  rm -rf run/coai; mkdir -p run/coai/config
  coai_channel() { # ID NAME PORT PRIORITY
    printf '    - id: %s\n      name: %s\n      type: openai\n      priority: %s\n      weight: 1\n      models:\n        - mock\n      retry: 1\n      secret: sk-standin\n      endpoint: http://127.0.0.1:%s\n      mapper: ""\n      state: true\n      group: []\n' "$1" "$2" "$4" "$3"
  }
  {
    echo 'channel:'
    # A higher priority is tried first.
    [ "${1:-}" = fallback ] && coai_channel 2 failing 9001 10
    coai_channel 1 standin 9000 0
    printf 'server:\n    port: 8094\n'
  } > run/coai/config/config.yaml
  PODMAN_USER= container_up coai 8094 -e MYSQL_HOST=127.0.0.1 -e MYSQL_PORT=3316 -e MYSQL_DB=arena -e MYSQL_USER=root -e MYSQL_PASSWORD=arena -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6389 \
    -e SECRET=arena-secret -e SERVE_STATIC=true -v "$(mount_of run/coai/config /config)" "$coai_image" || return 1
  for _ in $(seq 1 100); do
    token=$(curl -fsS -m 10 -H 'content-type: application/json' -d '{"username":"root","password":"chatnio123456"}' "$b/login" 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])' 2>/dev/null) && [ -n "$token" ] && break
    sleep 0.2
  done
  curl -fsS -m 10 -H "authorization: $token" "$b/apikey" | python3 -c 'import json, sys; print(json.load(sys.stdin)["key"])' > run/coai.key || { echo "CoAI didn't give its key" >&2; return 1; }
}
coai_key() { cat run/coai.key; }
coai_stop() { container_down coai; }
coai_clean() { container_down mysql redis; rm -rf run/coai run/coai.key; }
coai_mb() { containers_mb coai mysql redis; }
coai_cpu_us() { containers_cpu_us coai mysql redis; }
coai_skip() { echo "messages cache slow"; }
coai_features() { echo "routes by model through channels with priorities, retries on the next channel, takes OpenAI's format, checks the caller's key, counts usage and quota in MySQL"; }
