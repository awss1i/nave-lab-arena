# AxonHub, from its own official image, on PostgreSQL as its compose file runs it. It's set up through its admin
# API: the first account, the stand-in as a channel of OpenAI's type, and an API key in its default project. The
# database runs on the gateway's CPUs and its memory and CPU time count as AxonHub's.
axonhub_kind=container
axonhub_image=docker.io/looplj/axonhub:latest
axonhub_title() { echo AxonHub; }
axonhub_install() {
  "$CONTAINER" pull -q "$axonhub_image" > /dev/null
  version axonhub "$(image_version "$axonhub_image")"
}
axonhub_url() { echo http://127.0.0.1:8090; }
axonhub_start() { # MODE
  local b=http://127.0.0.1:8090 token
  "$CONTAINER" container inspect arena-postgres > /dev/null 2>&1 || postgres_up || return 1
  container_up axonhub 8090 -e AXONHUB_SERVER_HOST=127.0.0.1 -e AXONHUB_DB_DIALECT=postgres -e 'AXONHUB_DB_DSN=postgres://arena:arena@127.0.0.1:5442/arena?sslmode=disable' -e AXONHUB_LOG_LEVEL=error "$axonhub_image" || return 1
  for _ in $(seq 1 300); do curl -fsS -m 5 -o /dev/null "$b/admin/system/status" 2>/dev/null && break; sleep 0.1; done
  if [ ! -s run/axonhub.key ] || [ "$(cat run/axonhub.mode.done 2>/dev/null)" != "${1:-}" ]; then
    curl -fsS -m 30 -o /dev/null -H 'content-type: application/json' -d '{"ownerEmail":"arena@example.com","ownerPassword":"arena-password","ownerFirstName":"Arena","ownerLastName":"Race","brandName":"Arena"}' "$b/admin/system/initialize" 2>/dev/null
    token=$(curl -fsS -m 30 -H 'content-type: application/json' -d '{"email":"arena@example.com","password":"arena-password"}' "$b/admin/auth/signin" | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])') || { echo "AxonHub didn't sign the first account in" >&2; return 1; }
    axonhub_gql() { curl -fsS -m 30 -H "authorization: Bearer $token" -H 'X-Project-ID: gid://axonhub/Project/1' -H 'content-type: application/json' -d "$1" "$b/admin/graphql"; }
    axonhub_channel() { # NAME PORT WEIGHT
      local id
      id=$(axonhub_gql '{"query":"mutation($i: CreateChannelInput!){ createChannel(input:$i){ id } }","variables":{"i":{"type":"openai","baseURL":"http://127.0.0.1:'"$2"'/v1","name":"'"$1"'","credentials":{"apiKey":"sk-standin"},"supportedModels":["mock"],"defaultTestModel":"mock","orderingWeight":'"$3"'}}}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["createChannel"]["id"])') || return 1
      axonhub_gql '{"query":"mutation{ updateChannelStatus(id:\"'"$id"'\", status: enabled){ id } }"}' > /dev/null
    }
    if [ ! -s run/axonhub.key ]; then
      axonhub_channel standin 9000 1 || { echo "AxonHub didn't take the channel" >&2; return 1; }
      axonhub_gql '{"query":"mutation($i: CreateAPIKeyInput!){ createAPIKey(input:$i){ key } }","variables":{"i":{"name":"arena","projectID":"gid://axonhub/Project/1"}}}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["createAPIKey"]["key"])' > run/axonhub.key || return 1
    fi
    if [ "${1:-}" = fallback ]; then axonhub_channel failing 9001 100 || return 1; fi
    echo "${1:-}" > run/axonhub.mode.done
  fi
  # It reads its channels from the database on a timer, so the first right answer is waited for.
  for _ in $(seq 1 300); do
    curl -fsS -m 5 -o /dev/null -H "authorization: Bearer $(cat run/axonhub.key)" -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' "$b/v1/chat/completions" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "AxonHub never answered a call" >&2; return 1
}
axonhub_key() { cat run/axonhub.key; }
axonhub_messages_path() { echo /anthropic/v1/messages; }
axonhub_stop() { container_down axonhub; }
axonhub_clean() { container_down postgres; rm -f run/axonhub.key run/axonhub.mode.done; }
axonhub_mb() { containers_mb axonhub postgres; }
axonhub_cpu_us() { containers_cpu_us axonhub postgres; }
axonhub_skip() { echo cache; }
axonhub_features() { echo "routes by model through channels, retries on another channel, takes OpenAI's and Anthropic's formats, checks the caller's key, records every request and its usage in PostgreSQL"; }
