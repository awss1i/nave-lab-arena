# BricksLLM, from its own official image, with PostgreSQL and Redis as its compose repo runs it. It's set up through
# its admin API: the stand-in as a custom provider with one route, a provider setting holding the upstream's key,
# and a Bricks key for the caller. It checks the caller's key and counts each key's spend and requests. The
# databases run on the gateway's CPUs and count as its own.
bricksllm_kind=container
bricksllm_image=docker.io/luyuanxin1995/bricksllm:latest
bricksllm_title() { echo BricksLLM; }
bricksllm_install() {
  "$CONTAINER" pull -q "$bricksllm_image" > /dev/null
  version bricksllm "$(image_version "$bricksllm_image")"
}
bricksllm_url() { echo http://127.0.0.1:8002; }
bricksllm_chat_path() { echo /api/custom/providers/standin/chat/completions; }
bricksllm_start() { # MODE
  local a=http://127.0.0.1:8001 setting
  "$CONTAINER" container inspect arena-postgres > /dev/null 2>&1 || postgres_up || return 1
  "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
  PODMAN_USER= container_up bricksllm 8002 -e POSTGRESQL_HOSTS=127.0.0.1 -e POSTGRESQL_PORT=5442 -e POSTGRESQL_DB_NAME=arena -e POSTGRESQL_USERNAME=arena -e POSTGRESQL_PASSWORD=arena \
    -e REDIS_HOSTS=127.0.0.1 -e REDIS_PORT=6389 "$bricksllm_image" || return 1
  if [ ! -f run/bricksllm.configured ]; then
    for _ in $(seq 1 300); do curl -fsS -m 5 -o /dev/null "$a/api/custom/providers" 2>/dev/null && break; sleep 0.1; done
    curl -fsS -m 30 -o /dev/null -X POST -H 'content-type: application/json' -d '{"provider":"standin","route_configs":[{"path":"/chat/completions","target_url":"http://127.0.0.1:9000/v1/chat/completions","model_location":"model","stream_location":"stream","request_prompt_location":"messages.#.content","response_completion_location":"choices.0.message.content","stream_end_word":"[DONE]","stream_response_completion_location":"choices.0.delta.content","stream_max_empty_messages":10}],"authentication_param":"apikey"}' "$a/api/custom/providers" \
      || { echo "BricksLLM didn't take the custom provider" >&2; return 1; }
    setting=$(curl -fsS -m 30 -X PUT -H 'content-type: application/json' -d '{"provider":"standin","setting":{"apikey":"sk-standin"}}' "$a/api/provider-settings" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])') || return 1
    curl -fsS -m 30 -o /dev/null -X PUT -H 'content-type: application/json' -d '{"name":"arena","key":"arena-key","tags":["arena"],"settingIds":["'"$setting"'"]}' "$a/api/key-management/keys" || return 1
    touch run/bricksllm.configured
  fi
  # It reads its keys and settings from PostgreSQL on a timer, so the first right answer is waited for.
  for _ in $(seq 1 300); do
    curl -fsS -m 5 -o /dev/null -H 'authorization: Bearer arena-key' -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' "http://127.0.0.1:8002$(bricksllm_chat_path)" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "BricksLLM never answered a call" >&2; return 1
}
bricksllm_key() { echo arena-key; }
bricksllm_stop() { container_down bricksllm; }
bricksllm_clean() { container_down postgres redis; rm -f run/bricksllm.configured; }
bricksllm_mb() { containers_mb bricksllm postgres redis; }
bricksllm_cpu_us() { containers_cpu_us bricksllm postgres redis; }
bricksllm_skip() { echo "messages fallback cache"; }
bricksllm_features() { echo "passes OpenAI's format on to a custom provider's route, checks the caller's key, counts each key's requests and spend in PostgreSQL and Redis"; }
