# Helicone's platform, from its own all-in-one image: its web app, its API server Jawn, which also proxies calls,
# PostgreSQL, ClickHouse and MinIO in one container. A call goes through Jawn's proxy with two of Helicone's
# headers: its API key, so the call is logged to its platform, and the upstream's address, which it accepts for a
# local address. Three things are done to the image as shipped, each written here:
# - its ClickHouse listens on port 9000, the stand-in's, so a config file moves ClickHouse's native port
# - its ClickHouse migrations wait at a yes/no prompt and never run, so they're run with the script's own flag
# - it seeds no account, so one is made through its web app's sign-up and a key through Jawn's API
# The bundled "ai-gateway" process in the image fails to start and isn't used. That gateway is raced on its own
# as Helicone AI Gateway.
helicone_kind=container
helicone_image=docker.io/helicone/helicone-all-in-one:latest
helicone_title() { echo "Helicone"; }
helicone_install() {
  # The image is about 10 GB. On a GitHub runner, toolchains the arena doesn't use are removed to make room.
  if [ -n "${GITHUB_ACTIONS:-}" ]; then sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL; fi
  "$CONTAINER" pull -q "$helicone_image" > /dev/null
  version helicone "$(image_version "$helicone_image")"
}
helicone_url() { echo http://127.0.0.1:8585; }
helicone_chat_path() { echo /v1/gateway/oai/v1/chat/completions; }
helicone_messages_path() { echo /v1/gateway/anthropic/v1/messages; }
helicone_start() { # MODE
  local w=http://localhost:3000 cookie org
  mkdir -p run/helicone
  printf '<clickhouse>\n  <tcp_port>9010</tcp_port>\n  <interserver_http_port>9019</interserver_http_port>\n</clickhouse>\n' > run/helicone/ports.xml
  rm -f run/helicone.key
  PODMAN_USER= container_up helicone 8585 -v "$(mount_of run/helicone/ports.xml /etc/clickhouse-server/config.d/arena-ports.xml)" "$helicone_image" || return 1
  for _ in $(seq 1 600); do curl -fsS -m 5 -o /dev/null http://127.0.0.1:8585/healthcheck 2>/dev/null && break; sleep 0.2; done
  for _ in $(seq 1 600); do "$CONTAINER" exec arena-helicone curl -fsS -m 5 -o /dev/null http://localhost:8123/ping 2>/dev/null && break; sleep 0.2; done
  "$CONTAINER" exec arena-helicone sh -c 'cd /app/clickhouse && python3 ch_hcone.py --upgrade --no-password --skip-confirmation --host localhost --port 8123' > run/helicone/migrations.log 2>&1 \
    || { echo "Helicone's ClickHouse migrations failed: $(tail -2 run/helicone/migrations.log)" >&2; return 1; }
  for _ in $(seq 1 300); do curl -fsS -m 5 -o /dev/null "$w/api/auth/ok" 2>/dev/null && break; sleep 0.2; done
  for _ in $(seq 1 60); do
    curl -fsS -m 30 -o /dev/null -H 'content-type: application/json' -H "origin: $w" -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026!","name":"Arena"}' "$w/api/auth/sign-up/email" 2>/dev/null && break
    sleep 1
  done
  cookie=$(curl -fsS -m 30 -D - -o /dev/null -H 'content-type: application/json' -H "origin: $w" -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026!"}' "$w/api/auth/sign-in/email" | sed -n 's/^set-cookie: \(better-auth.session_token=[^;]*\).*/\1/ip' | tr -d '\r')
  [ -n "$cookie" ] || { echo "Helicone didn't sign the account in" >&2; return 1; }
  org=$("$CONTAINER" exec arena-helicone sh -c "PGPASSWORD=password psql -h localhost -U postgres -d helicone_test -At -c 'select id from organization limit 1'")
  curl -fsS -m 30 -H "cookie: $cookie" -H "origin: $w" -H 'content-type: application/json' -H "helicone-authorization: {\"_type\":\"jwt\",\"token\":\"x\",\"orgId\":\"$org\"}" \
    -d '{"api_key_name":"arena","key_permissions":"rw"}' http://localhost:8585/v1/api-keys | python3 -c 'import json, sys; print(json.load(sys.stdin)["apiKey"])' > run/helicone.key \
    || { echo "Helicone didn't make an API key" >&2; return 1; }
}
# The caller's key is the upstream's, passed on as Helicone's proxy does. Helicone's own key goes in its header.
helicone_key() { echo sk-standin; }
helicone_load_args() {
  printf '%s\n' --header "Helicone-Auth: Bearer $(cat run/helicone.key)" --header "Helicone-OpenAI-Api-Base: http://127.0.0.1:9000/v1" --header "Helicone-Target-Url: http://127.0.0.1:9000/v1"
}
helicone_skip() { echo "fallback cache"; }
helicone_features() { echo "passes OpenAI's and Anthropic's formats on to the upstream named in a header, checks its own API key, logs every call with its body to ClickHouse and MinIO, prices it. Its web app, PostgreSQL, ClickHouse and MinIO run in the same container and count as its own"; }
