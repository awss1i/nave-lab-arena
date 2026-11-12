# GPT-Load, from its own official image, set up through its management API the way its console does it: a group
# on the OpenAI channel whose base URL is the stand-in, with the model "mock" and one upstream key, and an access
# key for callers. Its data folder is a volume named for the arena, since it refuses a folder others can read.
gpt_load_kind=container
gpt_load_image=ghcr.io/tbphp/gpt-load:2
gpt_load_title() { echo GPT-Load; }
gpt_load_install() {
  "$CONTAINER" pull -q "$gpt_load_image" > /dev/null
  version gpt-load "$(image_version "$gpt_load_image")"
}
gpt_load_url() { echo http://127.0.0.1:3001; }
gpt_load_start() { # MODE
  local b=http://127.0.0.1:3001 id
  PODMAN_USER= container_up gpt-load 3001 -e HOST=127.0.0.1 -e PORT=3001 -e AUTH_KEY=arena-admin-key -e LOG_LEVEL=error -v arena-gpt-load-data:/app/data "$gpt_load_image" || return 1
  [ -s run/gpt-load.key ] && return 0
  gpt_load_api() { curl -fsS -m 30 -H 'authorization: Bearer arena-admin-key' -H 'content-type: application/json' -H "Idempotency-Key: $(python3 -c 'import uuid; print(uuid.uuid4())')" "$@"; }
  for _ in $(seq 1 300); do curl -fsS -m 2 -o /dev/null "$b/health" 2>/dev/null && break; sleep 0.1; done
  gpt_load_api -d '{"channel_id":"openai","connection_type":"api_key","params":{"base_url":"http://127.0.0.1:9000/v1"},"models":[{"id":"mock","alias_enabled":false}],"credentials":"sk-standin"}' "$b/api/groups" > /dev/null || { echo "GPT-Load didn't take the group" >&2; return 1; }
  id=$(gpt_load_api -d '{"name":"arena"}' "$b/api/access-keys" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["id"])') || return 1
  gpt_load_api -X POST "$b/api/access-keys/$id/reveal" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["key"])' > run/gpt-load.key || return 1
  for _ in $(seq 1 100); do
    curl -fsS -m 5 -o /dev/null -H "authorization: Bearer $(cat run/gpt-load.key)" -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' "$b/v1/chat/completions" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "GPT-Load never answered a call" >&2; return 1
}
gpt_load_key() { cat run/gpt-load.key; }
gpt_load_clean() { container_down gpt-load; sleep 1; "$CONTAINER" volume rm arena-gpt-load-data > /dev/null 2>&1; rm -f run/gpt-load.key; }
# A group on its OpenAI channel serves OpenAI's protocols only, so a call in Anthropic's format finds no route.
gpt_load_skip() { echo "messages fallback cache"; }
gpt_load_features() { echo "routes by model through groups of upstream keys, takes OpenAI's format on this channel, checks the caller's access key, records usage in SQLite"; }
