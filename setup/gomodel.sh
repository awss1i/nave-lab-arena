# GoModel, from its own official image, with its OpenAI provider's base URL set to the stand-in. It finds the model
# "mock" from the stand-in's models list. Its audit log of every call is off, since Nave's entrant keeps none, and
# its usage tracking stays on. It has no master key set, which is how it ships.
gomodel_kind=container
gomodel_image=docker.io/enterpilot/gomodel:latest
gomodel_title() { echo GoModel; }
gomodel_install() {
  "$CONTAINER" pull -q "$gomodel_image" > /dev/null
  version gomodel "$(image_version "$gomodel_image")"
}
gomodel_start() { # MODE
  local extra=()
  # Its exact-match response cache, which it keeps in Redis. Its failover is a virtual model with a strict priority list:
  # a second OpenAI provider that points at the failing stand-in comes first.
  if [ "${1:-}" = cache ]; then
    "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
    extra=(-e RESPONSE_CACHE_SIMPLE_ENABLED=true -e REDIS_URL=redis://127.0.0.1:6389)
  fi
  [ "${1:-}" = fallback ] && extra=(-e OPENAI_BAD_API_KEY=sk-standin -e OPENAI_BAD_BASE_URL=http://127.0.0.1:9001/v1 -e OPENAI_BAD_MODELS=mock
    -e 'VIRTUAL_MODELS=[{"source":"mock","strategy":"failover","targets":[{"model":"mock","provider":"openai-bad"},{"model":"mock","provider":"openai"}]}]')
  container_up gomodel 8080 -e PORT=8080 -e OPENAI_API_KEY=sk-standin -e OPENAI_BASE_URL=http://127.0.0.1:9000/v1 -e LOGGING_ENABLED=false -e LOG_LEVEL=error "${extra[@]}" "$gomodel_image"
}
gomodel_url() { echo http://127.0.0.1:8080; }
gomodel_skip() { echo ""; }
gomodel_features() { echo "routes by model, fails over through a virtual model in the fallback race, keeps exact repeats in Redis in the cache race, takes OpenAI's and Anthropic's formats, tracks usage. No key check, audit log off"; }
gomodel_clean() { container_down redis; }
# Its benchmark page (docs, about/benchmarks) sends 20,000 chat calls at a concurrency of 10 against an instant
# mock, with each gateway alone on two vCPUs, and gives GoModel 4,200 calls a second with 2.1 ms at the median.
gomodel_own_benchmark() { echo "0 20000 10||GoModel's benchmark of 20,000 chat calls with 10 open at once against an instant mock"; }
