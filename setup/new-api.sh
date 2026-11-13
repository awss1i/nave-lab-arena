# New API, from its own official image, with MySQL and its memory cache and batched updates on. It's set up the
# way its dashboard does it: the first-time setup makes the admin, then the stand-in is added as a channel of
# OpenAI's type and a token is made. It reads its channels at start, so it's restarted once after that. MySQL
# runs on the gateway's CPUs and its memory and CPU time count as New API's.
new_api_kind=container
new_api_image=docker.io/calciumion/new-api:latest
new_api_title() { echo "New API"; }
new_api_install() {
  "$CONTAINER" pull -q "$new_api_image" > /dev/null
  version new-api "$(image_version "$new_api_image")"
}
new_api_url() { echo http://127.0.0.1:3400; }
new_api_run() {
  "$CONTAINER" container inspect arena-mysql > /dev/null 2>&1 || mysql_up || return 1
  mkdir -p run/new-api-data && chmod 777 run/new-api-data
  container_up new-api 3400 -e PORT=3400 -e MEMORY_CACHE_ENABLED=true -e BATCH_UPDATE_ENABLED=true -e 'SQL_DSN=root:arena@tcp(127.0.0.1:3316)/arena' -v "$(mount_of run/new-api-data /data)" "$new_api_image"
}
new_api_start() { # MODE
  local b=http://127.0.0.1:3400 token
  new_api_run || return 1
  [ -f run/new-api.configured ] && return 0
  for _ in $(seq 1 300); do curl -fsS -m 2 -o /dev/null "$b/api/setup" 2>/dev/null && break; sleep 0.1; done
  curl -fsS -m 30 -H 'content-type: application/json' -d '{"username":"root","password":"arena-password-1","confirmPassword":"arena-password-1","SelfUseModeEnabled":false,"DemoSiteEnabled":false}' "$b/api/setup" > /dev/null || { echo "New API's first-time setup failed" >&2; return 1; }
  rm -f run/new-api.cookies
  token=$(curl -fsS -m 30 -c run/new-api.cookies -H 'content-type: application/json' -d '{"username":"root","password":"arena-password-1"}' "$b/api/user/login" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["access_token"])') || return 1
  new_api_api() { curl -fsS -m 30 -b run/new-api.cookies -H "authorization: Bearer $token" -H 'New-Api-User: 1' -H 'content-type: application/json' "$@"; }
  new_api_api -d '{"mode":"single","channel":{"type":1,"name":"standin","key":"sk-standin","base_url":"http://127.0.0.1:9000","models":"mock","group":"default","status":1}}' "$b/api/channel/" > /dev/null || return 1
  # For the fallback race: a second model name, served first by a channel that points at the failing stand-in and
  # then, at a lower priority, by the working one, with its retries switched on.
  new_api_api -d '{"mode":"single","channel":{"type":1,"name":"failing","key":"sk-standin","base_url":"http://127.0.0.1:9001","models":"mock-with-fallback","group":"default","status":1,"priority":10,"model_mapping":"{\"mock-with-fallback\":\"mock\"}"}}' "$b/api/channel/" > /dev/null || return 1
  new_api_api -d '{"mode":"single","channel":{"type":1,"name":"standin-second","key":"sk-standin","base_url":"http://127.0.0.1:9000","models":"mock-with-fallback","group":"default","status":1,"priority":0,"model_mapping":"{\"mock-with-fallback\":\"mock\"}"}}' "$b/api/channel/" > /dev/null || return 1
  new_api_api -X PUT -d '{"key":"RetryTimes","value":"2"}' "$b/api/option/" > /dev/null || return 1
  # It refuses a model that has no price, so both names get one.
  new_api_api -X PUT -d '{"key":"ModelRatio","value":"{\"mock\":1,\"mock-with-fallback\":1}"}' "$b/api/option/" > /dev/null || return 1
  new_api_api -d '{"name":"arena","remain_quota":0,"unlimited_quota":true,"expired_time":-1,"group":"default"}' "$b/api/token/" > /dev/null || return 1
  new_api_api -X POST "$b/api/token/1/key" | python3 -c 'import json, sys; print("sk-" + json.load(sys.stdin)["data"]["key"])' > run/new-api.key || return 1
  touch run/new-api.configured
  container_down new-api
  new_api_run
}
new_api_key() { cat run/new-api.key; }
new_api_stop() { container_down new-api; }
# MySQL holds its settings, so it stays up between races and goes down when the group is over.
new_api_clean() {
  container_down mysql
  rm -f run/new-api.configured run/new-api.key
  [ -d run/new-api-data ] || return 0
  if [ "$(basename "$CONTAINER")" = podman ]; then podman unshare rm -rf run/new-api-data; else sudo rm -rf run/new-api-data 2>/dev/null || rm -rf run/new-api-data; fi
}
new_api_mb() { containers_mb new-api mysql; }
new_api_cpu_us() { containers_cpu_us new-api mysql; }
new_api_skip() { echo "cache"; }
new_api_load_args() { [ "$(cat run/new-api.mode 2>/dev/null)" = fallback ] && printf '%s\n' --model mock-with-fallback; return 0; }
new_api_features() { echo "routes by model through channels, takes OpenAI's and Anthropic's formats, checks the caller's token, counts quota, logs each call to MySQL"; }
