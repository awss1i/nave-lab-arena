# Bifrost, from its own official image, with the model "mock" routed to the stand-in as an OpenAI provider. Its
# worker pool is set to the size its docs suggest for production, its request log is off, and Go is told how many
# CPUs it has.
bifrost_install() {
  "$CONTAINER" pull -q docker.io/maximhq/bifrost:latest > /dev/null
  version bifrost "$("$CONTAINER" image inspect docker.io/maximhq/bifrost:latest --format '{{index .Config.Labels "org.opencontainers.image.version"}} created {{.Created}}') (image docker.io/maximhq/bifrost:latest)"
}
bifrost_start() {
  mkdir -p run/bifrost-data && chmod 777 run/bifrost-data
  cat > run/bifrost-data/config.json <<'JSON'
{
  "$schema": "https://www.getbifrost.ai/schema",
  "client": { "enforce_auth_on_inference": false, "enable_logging": false, "initial_pool_size": 1000 },
  "providers": {
    "openai": {
      "keys": [{ "name": "standin", "value": "sk-standin", "models": ["mock"], "weight": 1.0 }],
      "network_config": { "base_url": "http://127.0.0.1:9000" }
    }
  }
}
JSON
  local mount="$PWD/run/bifrost-data:/app/data"
  [ "$(basename "$CONTAINER")" = podman ] && mount="$mount:Z"
  container_up bifrost 4300 -e APP_PORT=4300 -e APP_HOST=127.0.0.1 -e LOG_LEVEL=error -e GOMAXPROCS="$(echo "$GATEWAY_CPUS" | tr ',' '\n' | wc -l)" -v "$mount" docker.io/maximhq/bifrost:latest
}
bifrost_stop() { container_down bifrost; }
# Bifrost keeps its settings in a database beside config.json and builds it on its first start, which takes several
# seconds. It's removed once, before a group's races, so the first start happens in a race's setup and every timed
# start after it is a restart, as a restart in production would be.
bifrost_clean() {
  [ -d run/bifrost-data ] || return 0
  if [ "$(basename "$CONTAINER")" = podman ]; then podman unshare rm -rf run/bifrost-data; else sudo rm -rf run/bifrost-data 2>/dev/null || rm -rf run/bifrost-data; fi
}
bifrost_mb() { container_mb bifrost; }
