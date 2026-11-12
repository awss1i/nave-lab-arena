# Manifest (mnfst/llm-gateway), from its own official image, on PostgreSQL as its compose file runs it. It's set
# up through its API as its web page does: the first account, an agent whose key the calls carry, and the stand-in
# as a custom provider. A call names the model as "standin/mock", or "auto" in the fallback race, where every
# tier's model is the failing provider with the stand-in as its fallback. Its limits on calls a minute and calls
# at once are raised out of the way, since they'd cap the race. Telemetry and its update check are off. The
# database runs on the gateway's CPUs and counts as Manifest's.
manifest_kind=container
manifest_image=docker.io/manifestdotbuild/manifest:latest
manifest_title() { echo Manifest; }
manifest_install() {
  "$CONTAINER" pull -q "$manifest_image" > /dev/null
  version manifest "$(image_version "$manifest_image")"
}
manifest_url() { echo http://127.0.0.1:2099; }
manifest_start() { # MODE
  local a=http://localhost:2099 cookie tier
  "$CONTAINER" container inspect arena-postgres > /dev/null 2>&1 || postgres_up || return 1
  PODMAN_USER= container_up manifest 2099 -e PORT=2099 -e DATABASE_URL=postgresql://arena:arena@127.0.0.1:5442/arena -e BETTER_AUTH_SECRET=arena-auth-secret-arena-auth-secret-0000 \
    -e BETTER_AUTH_URL=http://localhost:2099 -e NODE_ENV=production -e MANIFEST_MODE=selfhosted -e SEED_DATA=false -e MANIFEST_TELEMETRY_DISABLED=1 -e MANIFEST_UPDATE_CHECK_DISABLED=1 \
    -e MANIFEST_CONCURRENCY_MAX=100000 -e MANIFEST_RATE_MAX_REQUESTS=100000000 -e MANIFEST_IP_RATE_MAX_REQUESTS=100000000 -e THROTTLE_LIMIT=100000000 \
    -e REQUEST_RECORDING_FILESYSTEM_PATH=/tmp/request-recordings "$manifest_image" || return 1
  for _ in $(seq 1 300); do curl -fsS -m 5 -o /dev/null "$a/api/v1/health" 2>/dev/null && break; sleep 0.1; done
  echo "${1:-}" > run/manifest.mode
  [ -s run/manifest.key ] && [ "$(cat run/manifest.mode.done 2>/dev/null)" = "${1:-}" ] && return 0
  curl -fsS -m 30 -o /dev/null -H 'content-type: application/json' -H "origin: $a" -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026!","name":"Arena"}' "$a/api/auth/sign-up/email" 2>/dev/null
  cookie=$(curl -fsS -m 30 -D - -o /dev/null -H 'content-type: application/json' -H "origin: $a" -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026!"}' "$a/api/auth/sign-in/email" | sed -n 's/^set-cookie: \(better-auth.session_token=[^;]*\).*/\1/ip' | tr -d '\r')
  [ -n "$cookie" ] || { echo "Manifest didn't sign the first account in" >&2; return 1; }
  manifest_api() { curl -fsS -m 30 -H "cookie: $cookie" -H "origin: $a" -H 'content-type: application/json' "$@"; }
  manifest_provider() { # NAME PORT
    manifest_api -o /dev/null -d '{"name":"'"$1"'","base_url":"http://127.0.0.1:'"$2"'/v1","api_kind":"openai","apiKey":"sk-standin","models":[{"model_name":"mock","input_price_per_million_tokens":1,"output_price_per_million_tokens":2}]}' "$a/api/v1/routing/arena/custom-providers"
  }
  if [ ! -s run/manifest.key ]; then
    manifest_api -d '{"name":"arena","autofix_enabled":false}' "$a/api/v1/agents" | python3 -c 'import json, sys; print(json.load(sys.stdin)["apiKey"])' > run/manifest.key || { echo "Manifest didn't make the agent" >&2; return 1; }
    manifest_provider standin 9000 || { echo "Manifest didn't take the provider" >&2; return 1; }
  fi
  if [ "${1:-}" = fallback ]; then
    manifest_provider failing 9001 || return 1
    for tier in $(manifest_api "$a/api/v1/routing/arena/tiers" | python3 -c 'import json, sys; print(" ".join(t["tier"] for t in json.load(sys.stdin)))'); do
      manifest_api -o /dev/null -X PUT -d '{"model":"failing/mock"}' "$a/api/v1/routing/arena/tiers/$tier" || return 1
      manifest_api -o /dev/null -X PUT -d '{"models":["standin/mock"]}' "$a/api/v1/routing/arena/tiers/$tier/fallbacks" || return 1
    done
  fi
  echo "${1:-}" > run/manifest.mode.done
}
manifest_key() { cat run/manifest.key; }
# It reads the key from the Authorization header in Anthropic's format too, where the load tool sends x-api-key.
manifest_load_args() { # KIND
  if [ "$(cat run/manifest.mode 2>/dev/null)" = fallback ]; then printf '%s\n' --model auto; else printf '%s\n' --model standin/mock; fi
  [ "${1:-}" = messages ] && printf '%s\n' --header "authorization: Bearer $(cat run/manifest.key)"
  return 0
}
manifest_stop() { container_down manifest; }
manifest_clean() { container_down postgres; rm -f run/manifest.key run/manifest.mode.done; }
manifest_mb() { containers_mb manifest postgres; }
manifest_cpu_us() { containers_cpu_us manifest postgres; }
manifest_skip() { echo cache; }
manifest_features() { echo "routes by model or by its own tiers, falls back, takes OpenAI's and Anthropic's formats, checks the caller's key, logs every call and its cost to PostgreSQL. Its limits on calls a minute and calls at once are raised out of the way"; }
