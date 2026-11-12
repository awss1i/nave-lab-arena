bifrost_kind=container
# Bifrost, from its own official image, with the model "mock" routed to the stand-in as an OpenAI provider. Its
# worker pool is set to the size its docs suggest for production, its request log is off, and Go is told how many
# CPUs it has.
bifrost_install() {
  "$CONTAINER" pull -q docker.io/maximhq/bifrost:latest > /dev/null
  version bifrost "$(bifrost_version) created $("$CONTAINER" image inspect docker.io/maximhq/bifrost:latest --format '{{.Created}}') (image docker.io/maximhq/bifrost:latest)"
}
# The image carries no version label, so the version is the release tag that Docker Hub lists with the same digest
# as `latest`.
bifrost_version() {
  curl -fsS -A arena 'https://hub.docker.com/v2/repositories/maximhq/bifrost/tags?page_size=50&ordering=last_updated' 2>/dev/null | python3 -c '
import json, re, sys
tags = json.load(sys.stdin)["results"]
latest = next((t["digest"] for t in tags if t["name"] == "latest"), None)
print(next((t["name"] for t in tags if t["digest"] == latest and re.fullmatch(r"v[0-9.]+", t["name"])), "version not found"))' 2>/dev/null || echo "version not found"
}
bifrost_start() { # MODE
  local first=9000 second=
  mkdir -p run/bifrost-data && chmod 777 run/bifrost-data
  if [ "${1:-}" = fallback ]; then
    # Its fallbacks are named in each request. The second provider is a custom one of OpenAI's kind.
    first=9001
    second=', "standin2": { "keys": [{ "name": "standin2", "value": "sk-standin", "models": ["mock"], "weight": 1.0 }], "network_config": { "base_url": "http://127.0.0.1:9000" }, "custom_provider_config": { "base_provider_type": "openai" } }'
  fi
  cat > run/bifrost-data/config.json <<JSON
{
  "\$schema": "https://www.getbifrost.ai/schema",
  "client": { "enforce_auth_on_inference": false, "enable_logging": false, "initial_pool_size": 1000 },
  "providers": {
    "openai": {
      "keys": [{ "name": "standin", "value": "sk-standin", "models": ["mock"], "weight": 1.0 }],
      "network_config": { "base_url": "http://127.0.0.1:$first" }
    }$second
  }
}
JSON
  local mount="$PWD/run/bifrost-data:/app/data"
  [ "$(basename "$CONTAINER")" = podman ] && mount="$mount:Z"
  container_up bifrost 4300 -e APP_PORT=4300 -e APP_HOST=127.0.0.1 -e LOG_LEVEL=error -e GOMAXPROCS="$(echo "$GATEWAY_CPUS" | tr ',' '\n' | wc -l)" -v "$mount" docker.io/maximhq/bifrost:latest
}
# Bifrost keeps its settings in a database beside config.json and builds it on its first start, which takes several
# seconds. It's removed once, before a group's races, so the first start happens in a race's setup and every timed
# start after it is a restart, as a restart in production would be.
bifrost_clean() {
  [ -d run/bifrost-data ] || return 0
  if [ "$(basename "$CONTAINER")" = podman ]; then podman unshare rm -rf run/bifrost-data; else sudo rm -rf run/bifrost-data 2>/dev/null || rm -rf run/bifrost-data; fi
}
bifrost_url() { echo http://127.0.0.1:4300; }
bifrost_load_args() {
  printf '%s\n' --model openai/mock
  [ "$(cat run/bifrost.mode 2>/dev/null)" = fallback ] && printf '%s\n' --field 'fallbacks=["standin2/mock"]'
}
bifrost_messages_path() { echo /anthropic/v1/messages; }
bifrost_features() { echo "routes by provider and model, takes OpenAI's and Anthropic's formats, keeps its settings in a database. Key check off, request log off, as its own benchmark runs it"; }
# Its cache is by meaning and needs a vector store.
bifrost_skip() { echo cache; }
bifrost_title() { echo "Bifrost"; }
bifrost_image=docker.io/maximhq/bifrost:latest
# Its own benchmark is 5,000 calls a second on four vCPUs against a mock (docs/benchmarking/t3.xl). Its mock took about
# 1.5 s a call, which would hold 7,500 calls open, so the model here takes 100 ms.
bifrost_own_benchmark() { echo "5000 50000 1024|--first-ms 100|Bifrost's test of 5,000 calls a second, against a model that takes 100 ms where Bifrost's own took about 1.5 s"; }
