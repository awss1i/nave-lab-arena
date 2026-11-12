# Claude Relay Service, from its own official image, with Redis as its compose file runs it. It's built to share
# Claude subscriptions, which need a sign-in, and it also takes an upstream of its "Claude Console" kind, which
# is an address and a key in Anthropic's format. That's how the stand-in is set here, through its admin API,
# along with a key for the caller. Its main path takes Anthropic's format, so its whole job runs in that format.
# Redis runs on the gateway's CPUs and counts as its own.
claude_relay_service_kind=container
claude_relay_service_image=docker.io/weishaw/claude-relay-service:latest
claude_relay_service_title() { echo "Claude Relay Service"; }
claude_relay_service_install() {
  "$CONTAINER" pull -q "$claude_relay_service_image" > /dev/null
  version claude-relay-service "$(image_version "$claude_relay_service_image")"
}
claude_relay_service_url() { echo http://127.0.0.1:3310; }
claude_relay_service_start() { # MODE
  local b=http://127.0.0.1:3310 token
  "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
  PODMAN_USER= container_up claude-relay-service 3310 -e PORT=3310 -e HOST=127.0.0.1 -e NODE_ENV=production -e JWT_SECRET=arena-jwt-secret-arena-jwt-secret-0000 \
    -e ENCRYPTION_KEY=arenaarenaarenaarenaarenaarena00 -e ADMIN_USERNAME=arena_admin -e ADMIN_PASSWORD=Arena-Race-Pass-2026 -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6389 \
    -e LOG_LEVEL=error "$claude_relay_service_image" || return 1
  for _ in $(seq 1 300); do curl -fsS -m 5 -o /dev/null "$b/health" 2>/dev/null && break; sleep 0.1; done
  [ -s run/claude-relay-service.key ] && [ "$(cat run/claude-relay-service.mode.done 2>/dev/null)" = "${1:-}" ] && return 0
  for _ in $(seq 1 100); do
    token=$(curl -fsS -m 10 -H 'content-type: application/json' -d '{"username":"arena_admin","password":"Arena-Race-Pass-2026"}' "$b/web/auth/login" 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])' 2>/dev/null) && [ -n "$token" ] && break
    sleep 0.2
  done
  claude_relay_service_api() { curl -fsS -m 30 -H "authorization: Bearer $token" -H 'content-type: application/json' "$@"; }
  claude_relay_service_account() { # NAME PORT PRIORITY, where a lower number is tried first
    claude_relay_service_api -o /dev/null -d '{"name":"'"$1"'","apiUrl":"http://127.0.0.1:'"$2"'","apiKey":"sk-standin","priority":'"$3"',"accountType":"shared","maxConcurrentTasks":0}' "$b/admin/claude-console-accounts"
  }
  if [ ! -s run/claude-relay-service.key ]; then
    claude_relay_service_account standin 9000 50 || { echo "Claude Relay Service didn't take the account" >&2; return 1; }
    claude_relay_service_api -d '{"name":"arena","permissions":"all"}' "$b/admin/api-keys" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["apiKey"])' > run/claude-relay-service.key || return 1
  fi
  if [ "${1:-}" = fallback ]; then claude_relay_service_account failing 9001 1 || return 1; fi
  echo "${1:-}" > run/claude-relay-service.mode.done
}
claude_relay_service_key() { cat run/claude-relay-service.key; }
claude_relay_service_format() { echo messages; }
claude_relay_service_messages_path() { echo /api/v1/messages; }
claude_relay_service_stop() { container_down claude-relay-service; }
claude_relay_service_clean() { container_down redis; rm -f run/claude-relay-service.key run/claude-relay-service.mode.done; }
claude_relay_service_mb() { containers_mb claude-relay-service redis; }
claude_relay_service_cpu_us() { containers_cpu_us claude-relay-service redis; }
# It has no fallback for a call: with a failing account first, the first calls get the account's error back (8 of
# 200 when tried in the lab) and later calls go to the next account. So it stays out of the fallback race.
claude_relay_service_skip() { echo "fallback cache"; }
claude_relay_service_features() { echo "routes to an upstream account by priority, moves later calls to another account when one fails, takes Anthropic's format, checks the caller's key, counts usage and cost in Redis. Its subscription sign-ins aren't used"; }
