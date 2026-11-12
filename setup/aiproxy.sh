# AI Proxy, from its own official image, with PostgreSQL and Redis as its compose file runs it. It's set up
# through its admin API: a model config for "mock", the stand-in as a channel of OpenAI's type, a group and a
# token. The databases run on the gateway's CPUs and their memory and CPU time count as AI Proxy's.
aiproxy_kind=container
aiproxy_image=ghcr.io/labring/aiproxy:latest
aiproxy_title() { echo "AI Proxy"; }
aiproxy_install() {
  "$CONTAINER" pull -q "$aiproxy_image" > /dev/null
  version aiproxy "$(image_version "$aiproxy_image")"
}
aiproxy_url() { echo http://127.0.0.1:3500; }
aiproxy_start() { # MODE
  local b=http://127.0.0.1:3500
  "$CONTAINER" container inspect arena-postgres > /dev/null 2>&1 || postgres_up || return 1
  "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
  container_up aiproxy 3500 -e LISTEN=127.0.0.1:3500 -e ADMIN_KEY=arena-admin -e 'SQL_DSN=postgres://arena:arena@127.0.0.1:5442/arena?sslmode=disable' -e REDIS=redis://127.0.0.1:6389 "$aiproxy_image" || return 1
  [ -s run/aiproxy.key ] && return 0
  aiproxy_api() { curl -fsS -m 30 -H 'authorization: arena-admin' -H 'content-type: application/json' "$@"; }
  for _ in $(seq 1 300); do aiproxy_api -o /dev/null "$b/api/channels/type_metas" 2>/dev/null && break; sleep 0.1; done
  aiproxy_api -d '{"model":"mock","owner":"openai","type":1,"rpm":0,"tpm":0}' "$b/api/model_config/mock" > /dev/null || { echo "AI Proxy didn't take the model config" >&2; return 1; }
  aiproxy_api -d '{"type":1,"name":"standin","key":"sk-standin","base_url":"http://127.0.0.1:9000/v1","models":["mock"],"status":1}' "$b/api/channel/" > /dev/null || return 1
  aiproxy_api -d '{}' "$b/api/group/arena" > /dev/null || return 1
  aiproxy_api -d '{"name":"arena"}' "$b/api/token/arena" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["key"])' > run/aiproxy.key || return 1
  # It caches its channels and tokens, so the first right answer is waited for.
  for _ in $(seq 1 100); do
    curl -fsS -m 5 -o /dev/null -H "authorization: Bearer $(cat run/aiproxy.key)" -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' "$b/v1/chat/completions" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "AI Proxy never answered a call" >&2; return 1
}
aiproxy_key() { cat run/aiproxy.key; }
aiproxy_stop() { container_down aiproxy; }
aiproxy_clean() { container_down postgres redis; rm -f run/aiproxy.key; }
aiproxy_mb() { containers_mb aiproxy postgres redis; }
aiproxy_cpu_us() { containers_cpu_us aiproxy postgres redis; }
aiproxy_skip() { echo "fallback cache"; }
aiproxy_features() { echo "routes by model through channels, takes OpenAI's and Anthropic's formats, checks the caller's token, counts usage, logs each call to PostgreSQL"; }
