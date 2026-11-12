# Higress, from its own all-in-one image, set up through its console's API the way the console does it: the first
# admin, the stand-in as a provider of OpenAI's type with a custom address, and an AI route to it. Its settings
# live in a data folder that is kept between starts, so a timed start is a restart.
higress_kind=container
higress_image=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/all-in-one:latest
higress_title() { echo Higress; }
higress_install() {
  "$CONTAINER" pull -q "$higress_image" > /dev/null
  version higress "$(image_version "$higress_image")"
}
higress_url() { echo http://127.0.0.1:8080; }
higress_ready() {
  for _ in $(seq 1 600); do
    curl -fsS -m 5 -o /dev/null -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:8080/v1/chat/completions 2>/dev/null && return 0
    sleep 0.1
  done
  echo "Higress never answered a call" >&2; return 1
}
higress_start() { # MODE
  local b=http://127.0.0.1:8001
  mkdir -p run/higress-data && chmod 777 run/higress-data
  PODMAN_USER= container_up higress 8001 -v "$(mount_of run/higress-data /data)" "$higress_image" || return 1
  if [ ! -f run/higress.configured ]; then
    higress_api() { curl -fsS -m 30 -b run/higress.cookies -c run/higress.cookies -H 'content-type: application/json' "$@"; }
    for _ in $(seq 1 600); do curl -fsS -m 2 -o /dev/null "$b/system/info" 2>/dev/null && break; sleep 0.2; done
    rm -f run/higress.cookies
    higress_api -d '{"adminUser":{"name":"admin","displayName":"admin","password":"arena-higress-1"}}' "$b/system/init" > /dev/null || { echo "Higress's first-time setup failed" >&2; return 1; }
    higress_api -d '{"username":"admin","password":"arena-higress-1"}' "$b/session/login" > /dev/null || return 1
    higress_api -d '{"name":"standin","type":"openai","protocol":"openai/v1","tokens":["sk-standin"],"rawConfigs":{"openaiCustomUrl":"http://127.0.0.1:9000/v1"}}' "$b/v1/ai/providers" > /dev/null || return 1
    higress_api -d '{"name":"mock","upstreams":[{"provider":"standin","weight":100}],"pathPredicate":{"matchType":"PRE","matchValue":"/v1","caseSensitive":true}}' "$b/v1/ai/routes" > /dev/null || return 1
    touch run/higress.configured
  fi
  higress_ready
}
higress_clean() {
  rm -f run/higress.configured run/higress.cookies
  [ -d run/higress-data ] || return 0
  if [ "$(basename "$CONTAINER")" = podman ]; then podman unshare rm -rf run/higress-data; else sudo rm -rf run/higress-data 2>/dev/null || rm -rf run/higress-data; fi
}
higress_skip() { echo "messages fallback cache"; }
higress_features() { echo "routes through an AI route and its ai-proxy plugin on Envoy, takes OpenAI's format. No key check"; }
