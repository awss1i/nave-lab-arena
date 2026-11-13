# sub2api, from its own official image, on PostgreSQL and Redis, in its simple mode. It's set up the way its console
# does it: the admin signs in, acknowledges its Deployment and Operation Compliance Commitment by typing the phrase
# its console asks for (awss1i's yes to that is ruling 46, and the instance here serves the stand-in model only, with
# no real upstream account), adds the stand-in as an upstream account of OpenAI's kind with an API key, and makes a
# caller's key in its default OpenAI group. PostgreSQL and Redis run on the gateway's CPUs and count as sub2api's.
sub2api_kind=container
sub2api_image=docker.io/weishaw/sub2api:latest
sub2api_title() { echo sub2api; }
sub2api_install() {
  "$CONTAINER" pull -q "$sub2api_image" > /dev/null
  version sub2api "$(image_version "$sub2api_image")"
}
sub2api_url() { echo http://127.0.0.1:8380; }
sub2api_run() {
  "$CONTAINER" container inspect arena-postgres > /dev/null 2>&1 || postgres_up || return 1
  "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
  PODMAN_USER= container_up sub2api 8380 -e AUTO_SETUP=true -e SERVER_HOST=127.0.0.1 -e SERVER_PORT=8380 -e SERVER_MODE=release -e RUN_MODE=simple \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5442 -e DATABASE_USER=arena -e DATABASE_PASSWORD=arena -e DATABASE_DBNAME=arena -e DATABASE_SSLMODE=disable \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6389 -e ADMIN_EMAIL=arena@example.com -e ADMIN_PASSWORD=Arena-Race-Pass-2026 -e JWT_SECRET=arena-jwt-secret-arena-jwt-secret-0000 -e TZ=UTC "$sub2api_image"
}
sub2api_start() { # MODE
  local b=http://127.0.0.1:8380 token
  sub2api_run || return 1
  [ -f run/sub2api.configured ] && return 0
  for _ in $(seq 1 300); do curl -fsS -m 2 -o /dev/null "$b/health" 2> /dev/null && break; sleep 0.1; done
  token=$(curl -fsS -m 30 -H 'content-type: application/json' -d '{"email":"arena@example.com","password":"Arena-Race-Pass-2026"}' "$b/api/v1/auth/login" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["access_token"])') || { echo "sub2api's admin didn't sign in" >&2; return 1; }
  sub2api_api() { curl -fsS -m 30 -H "authorization: Bearer $token" -H 'content-type: application/json' "$@"; }
  sub2api_api -o /dev/null -d '{"phrase":"I have read, understood, and agree to the Sub2API Deployment and Operation Compliance Commitment","language":"en"}' "$b/api/v1/admin/compliance/accept" || { echo "sub2api didn't take the acknowledgement" >&2; return 1; }
  sub2api_api -o /dev/null -d '{"name":"standin","platform":"openai","type":"apikey","credentials":{"api_key":"sk-standin","base_url":"http://127.0.0.1:9000"},"concurrency":100000,"priority":1,"group_ids":[]}' "$b/api/v1/admin/accounts" || return 1
  group=$(sub2api_api "$b/api/v1/admin/groups" | python3 -c 'import json, sys; print(next(g["id"] for g in json.load(sys.stdin)["data"]["items"] if g["platform"] == "openai"))') || return 1
  sub2api_api -d "{\"name\":\"arena\",\"group_id\":$group}" "$b/api/v1/keys" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["key"])' > run/sub2api.key || return 1
  touch run/sub2api.configured
}
sub2api_key() { cat run/sub2api.key; }
sub2api_stop() { container_down sub2api; }
# PostgreSQL holds its settings, so it stays up between races and goes down when the group is over.
sub2api_clean() { container_down postgres redis; rm -f run/sub2api.configured run/sub2api.key; }
sub2api_mb() { containers_mb sub2api postgres redis; }
sub2api_cpu_us() { containers_cpu_us sub2api postgres redis; }
# Its OpenAI group doesn't take calls in Anthropic's format, and no second upstream or cache is set up for it.
sub2api_skip() { echo "messages fallback cache"; }
sub2api_features() { echo "routes by group to upstream accounts, takes OpenAI's format and sends it on as a Responses call, checks the caller's key, counts usage and quota in PostgreSQL. Simple mode, as its docs give for one owner"; }
