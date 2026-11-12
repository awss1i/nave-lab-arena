# 9Router, from its own official image. It's set up through its management API, the way its dashboard does it: a
# provider node for the stand-in as an OpenAI-compatible provider, a connection on that node, and a key for the
# caller. Its fallback is a combo of models tried in order. Its settings live in a data folder kept between starts.
# The image drops from root to its own user itself, so it starts as its own root.
nine_router_kind=container
nine_router_image=docker.io/decolua/9router:latest
nine_router_title() { echo 9Router; }
nine_router_install() {
  "$CONTAINER" pull -q "$nine_router_image" > /dev/null
  version 9router "$("$CONTAINER" run --rm --entrypoint node "$nine_router_image" -e "console.log(require('./package.json').version)" 2>/dev/null) (image $nine_router_image)"
}
nine_router_url() { echo http://127.0.0.1:20128; }
nine_router_api() { # METHOD PATH [JSON]
  curl -fsS -m 30 -b run/nine-router.cookies -c run/nine-router.cookies -X "$1" -H 'content-type: application/json' ${3:+-d "$3"} "http://127.0.0.1:20128$2"
}
nine_router_node() { # NAME PORT
  local id
  id=$(nine_router_api POST /api/provider-nodes "{\"name\":\"$1\",\"prefix\":\"$1\",\"apiType\":\"chat\",\"type\":\"openai-compatible\",\"baseUrl\":\"http://127.0.0.1:$2/v1\"}" | python3 -c 'import json, sys; print(json.load(sys.stdin)["node"]["id"])') || return 1
  nine_router_api POST /api/providers "{\"provider\":\"$id\",\"name\":\"$1\",\"apiKey\":\"sk-standin\"}" > /dev/null
}
nine_router_start() { # MODE
  local data="run/nine-router-data-${1:-plain}"
  [ -d "$data" ] || { mkdir -p "$data" && chmod 777 "$data"; }
  echo "${1:-}" > run/nine-router.mode
  PODMAN_USER= container_up nine-router 20128 -e PORT=20128 -e HOSTNAME=127.0.0.1 -e DATA_DIR=/app/data -e INITIAL_PASSWORD=arena-management -v "$(mount_of "$data" /app/data)" "$nine_router_image" || return 1
  [ -s "$data/.arena-key" ] && { cp "$data/.arena-key" run/nine-router.key; return 0; }
  for _ in $(seq 1 600); do curl -fsS -m 2 -o /dev/null http://127.0.0.1:20128/api/settings/require-login 2>/dev/null && break; sleep 0.1; done
  rm -f run/nine-router.cookies
  nine_router_api POST /api/auth/login '{"password":"arena-management"}' > /dev/null || { echo "9Router's management login failed" >&2; return 1; }
  nine_router_node standin 9000 || { echo "9Router didn't take the stand-in as a provider" >&2; return 1; }
  if [ "${1:-}" = fallback ]; then
    nine_router_node failing 9001 || return 1
    nine_router_api POST /api/combos '{"name":"mock-with-fallback","models":["failing/mock","standin/mock"]}' > /dev/null || { echo "9Router didn't take the combo" >&2; return 1; }
  fi
  nine_router_api POST /api/keys '{"name":"arena"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["key"])' > run/nine-router.key || return 1
  cp run/nine-router.key "$data/.arena-key"
}
nine_router_key() { cat run/nine-router.key; }
# A call that doesn't say whether it's streamed gets a stream back from 9Router, so the calls that aren't streamed
# say so.
nine_router_load_args() { # KIND LOAD-OPTIONS
  if [ "$(cat run/nine-router.mode 2>/dev/null)" = fallback ]; then printf '%s\n' --model mock-with-fallback; else printf '%s\n' --model standin/mock; fi
  case " ${2:-} " in *" --stream "*|*" --replay "*) ;; *) printf '%s\n' --field stream=false;; esac
}
nine_router_clean() {
  local d
  for d in run/nine-router-data-plain run/nine-router-data-fallback; do
    [ -d "$d" ] || continue
    if [ "$(basename "$CONTAINER")" = podman ]; then podman unshare rm -rf "$d"; else sudo rm -rf "$d" 2>/dev/null || rm -rf "$d"; fi
  done
  rm -f run/nine-router.key run/nine-router.cookies run/nine-router.mode
}
nine_router_skip() { echo cache; }
nine_router_features() { echo "routes by provider and model, falls back through a combo, takes OpenAI's and Anthropic's formats, checks the caller's key, keeps its settings and usage in a data folder"; }
