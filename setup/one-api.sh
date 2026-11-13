# One API, from its own official image, with MySQL, which its README says to use under load, and its memory cache
# and batched updates on. It's set up the way its dashboard does it: sign in as the first admin, add the stand-in
# as a channel of OpenAI's type, and make a token. It reads its channels at start, so it's restarted once after
# that. MySQL runs on the gateway's CPUs and its memory and CPU time count as One API's.
one_api_kind=container
one_api_image=docker.io/justsong/one-api:latest
one_api_title() { echo "One API"; }
one_api_install() {
  "$CONTAINER" pull -q "$one_api_image" > /dev/null
  version one-api "$(image_version "$one_api_image")"
}
one_api_url() { echo http://127.0.0.1:3300; }
one_api_run() {
  "$CONTAINER" container inspect arena-mysql > /dev/null 2>&1 || mysql_up || return 1
  container_up one-api 3300 -e MEMORY_CACHE_ENABLED=true -e BATCH_UPDATE_ENABLED=true -e 'SQL_DSN=root:arena@tcp(127.0.0.1:3316)/arena' "$one_api_image" --port 3300 --log-dir /tmp
}
one_api_api() { # METHOD PATH [JSON]
  curl -fsS -m 30 -b run/one-api.cookies -c run/one-api.cookies -X "$1" -H 'content-type: application/json' ${3:+-d "$3"} "http://127.0.0.1:3300$2"
}
one_api_start() { # MODE
  one_api_run || return 1
  [ -f run/one-api.configured ] && return 0
  for _ in $(seq 1 300); do curl -fsS -m 2 -o /dev/null http://127.0.0.1:3300/api/status 2>/dev/null && break; sleep 0.1; done
  rm -f run/one-api.cookies
  one_api_api POST /api/user/login '{"username":"root","password":"123456"}' > /dev/null || { echo "One API's first sign-in failed" >&2; return 1; }
  one_api_api POST /api/channel/ '{"type":1,"name":"standin","key":"sk-standin","base_url":"http://127.0.0.1:9000","models":"mock","group":"default","groups":["default"],"model_mapping":"","priority":0}' > /dev/null || return 1
  # For the fallback race: a second model name, served first by a channel that points at the failing stand-in and
  # then, at a lower priority, by the working one, and two retries, since its first retry stays at the same priority.
  one_api_api POST /api/channel/ '{"type":1,"name":"failing","key":"sk-standin","base_url":"http://127.0.0.1:9001","models":"mock-with-fallback","group":"default","groups":["default"],"model_mapping":"{\"mock-with-fallback\":\"mock\"}","priority":10}' > /dev/null || return 1
  one_api_api POST /api/channel/ '{"type":1,"name":"standin-second","key":"sk-standin","base_url":"http://127.0.0.1:9000","models":"mock-with-fallback","group":"default","groups":["default"],"model_mapping":"{\"mock-with-fallback\":\"mock\"}","priority":0}' > /dev/null || return 1
  one_api_api PUT /api/option/ '{"key":"RetryTimes","value":"2"}' > /dev/null || return 1
  one_api_api POST /api/token/ '{"name":"arena","remain_quota":0,"unlimited_quota":true,"expired_time":-1}' > /dev/null || return 1
  one_api_api GET '/api/token/?p=0' | python3 -c 'import json, sys; print("sk-" + json.load(sys.stdin)["data"][0]["key"])' > run/one-api.key || return 1
  touch run/one-api.configured
  container_down one-api
  one_api_run
}
one_api_key() { cat run/one-api.key; }
one_api_stop() { container_down one-api; }
# MySQL holds its settings, so it stays up between races and goes down when the group is over.
one_api_clean() { container_down mysql; rm -f run/one-api.configured run/one-api.key; }
one_api_mb() { containers_mb one-api mysql; }
one_api_cpu_us() { containers_cpu_us one-api mysql; }
# Its `/v1/messages` isn't an endpoint it has.
one_api_skip() { echo "messages cache"; }
one_api_load_args() { [ "$(cat run/one-api.mode 2>/dev/null)" = fallback ] && printf '%s\n' --model mock-with-fallback; return 0; }
one_api_features() { echo "routes by model through channels, retries on a lower-priority channel in the fallback race, takes OpenAI's format, checks the caller's token, counts quota, logs each call to MySQL"; }
