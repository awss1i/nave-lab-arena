# OmniRoute, from its own official image. RATE_LIMIT_AUTO_ENABLE=false is the setting its docs give for running
# API-key providers without its rate-limit queue, which otherwise paces an unknown provider to about a call a second.
# DISABLE_SQLITE_AUTO_BACKUP=true is how its own performance baseline runs it. It's set up through its management API, the way its dashboard does it:
# a provider node for the stand-in as an OpenAI-compatible provider, and a connection on that node. Its key check
# is off, since Nave's entrant has none. Its settings live in a data folder, which is kept between starts, so a
# timed start is a restart with its settings already there.
omniroute_kind=container
omniroute_image=docker.io/diegosouzapw/omniroute:latest
omniroute_title() { echo OmniRoute; }
omniroute_install() {
  "$CONTAINER" pull -q "$omniroute_image" > /dev/null
  version omniroute "$("$CONTAINER" run --rm --entrypoint node "$omniroute_image" -e "console.log(require('./package.json').version)") (image $omniroute_image)"
}
omniroute_url() { echo http://127.0.0.1:20128; }
omniroute_api() { # METHOD PATH [JSON]
  curl -fsS -m 30 -b run/omniroute.cookies -c run/omniroute.cookies -X "$1" -H 'content-type: application/json' ${3:+-d "$3"} "http://127.0.0.1:20128$2"
}
# A node and an active connection for a stand-in on PORT, under the prefix NAME.
omniroute_node() { # NAME PORT
  local id
  omniroute_api POST /api/provider-nodes "{\"name\":\"$1\",\"prefix\":\"$1\",\"apiType\":\"chat\",\"type\":\"openai-compatible\",\"baseUrl\":\"http://127.0.0.1:$2/v1\",\"providerIdSuffix\":\"$1\"}" > /dev/null || return 1
  id=$(omniroute_api POST /api/providers "{\"provider\":\"openai-compatible-chat-$1\",\"name\":\"$1\",\"apiKey\":\"sk-standin\",\"url\":\"http://127.0.0.1:$2/v1\"}" | python3 -c 'import json, sys; print(json.load(sys.stdin)["connection"]["id"])') || return 1
  omniroute_api PUT "/api/providers/$id" '{"isActive":true}' > /dev/null
}
omniroute_start() { # MODE
  # The edge checks get a data folder of their own: after an upstream's 429 it sets the provider aside for a
  # while, and that would carry into the next race's start.
  local tag mount data
  tag=$(cat run/omniroute.mode 2>/dev/null)
  data="run/omniroute-data-${tag:-plain}"
  mkdir -p "$data" && chmod 777 "$data"
  mount="$PWD/$data:/app/data"
  [ "$(basename "$CONTAINER")" = podman ] && mount="$mount:Z"
  container_up omniroute 20128 -e PORT=20128 -e HOSTNAME=127.0.0.1 -e REQUIRE_API_KEY=false -e RATE_LIMIT_AUTO_ENABLE=false -e DISABLE_SQLITE_AUTO_BACKUP=true -e INITIAL_PASSWORD=arena-management -v "$mount" "$omniroute_image" || return 1
  [ -f "$data/.arena-configured" ] && return 0
  # The port answers before the management API does.
  for _ in $(seq 1 600); do curl -fsS -m 2 -o /dev/null http://127.0.0.1:20128/api/settings/require-login 2>/dev/null && break; sleep 0.1; done
  rm -f run/omniroute.cookies
  omniroute_api POST /api/auth/login '{"password":"arena-management"}' > /dev/null || { echo "OmniRoute's management login failed" >&2; return 1; }
  omniroute_node standin 9000 || { echo "OmniRoute didn't take the stand-in as a provider" >&2; return 1; }
  if [ "${1:-}" = fallback ]; then
    # Its fallback is a combo: the failing provider first, then the working one.
    omniroute_node failing 9001 || return 1
    omniroute_api POST /api/combos '{"name":"mock-with-fallback","models":["failing/mock","standin/mock"],"strategy":"priority"}' > /dev/null || { echo "OmniRoute didn't take the combo" >&2; return 1; }
  fi
  touch "$data/.arena-configured"
}
omniroute_load_args() {
  if [ "$(cat run/omniroute.mode 2>/dev/null)" = fallback ]; then printf '%s\n' --model mock-with-fallback; else printf '%s\n' --model standin/mock; fi
  # Its cache, on as it ships, keeps answers to calls sent with temperature 0 and no others.
  [ "$(cat run/omniroute.mode 2>/dev/null)" = cache ] && printf '%s\n' --field temperature=0
  return 0
}
omniroute_clean() {
  for d in run/omniroute-data-*; do
    [ -d "$d" ] || continue
    if [ "$(basename "$CONTAINER")" = podman ]; then podman unshare rm -rf "$d"; else sudo rm -rf "$d" 2>/dev/null || rm -rf "$d"; fi
  done
}
# It carries tens of calls a second here, so its whole job doesn't fit a runner's time limit (one was cancelled at
# 150 minutes before its last two races). It gets the cut-down job the other slow gateways get.
omniroute_skip() { echo "slow"; }
omniroute_features() { echo "routes by provider and model, falls back through a combo, keeps answers to calls sent with temperature 0, takes OpenAI's and Anthropic's formats, keeps its settings, usage and a log of calls in SQLite. Key check off"; }
