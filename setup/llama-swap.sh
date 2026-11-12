# llama-swap, from its own official CPU image. It starts a model's server on demand and passes calls on to it, so
# here the model "mock" has a command that only waits, and its address is the stand-in.
llama_swap_kind=container
llama_swap_image=ghcr.io/mostlygeek/llama-swap:cpu
llama_swap_title() { echo llama-swap; }
llama_swap_install() {
  "$CONTAINER" pull -q "$llama_swap_image" > /dev/null
  version llama-swap "$("$CONTAINER" run --rm --entrypoint /app/llama-swap "$llama_swap_image" -version 2>/dev/null | head -1) (image $llama_swap_image)"
}
llama_swap_start() { # MODE
  mkdir -p run/llama-swap
  cat > run/llama-swap/config.yaml <<'YAML'
healthCheckTimeout: 30
logLevel: error
models:
  mock:
    cmd: sleep 1000000
    proxy: http://127.0.0.1:9000
    checkEndpoint: /v1/models
    ttl: 0
YAML
  PODMAN_USER= container_up llama-swap 8480 -v "$(mount_of run/llama-swap/config.yaml /app/config.yaml)" --entrypoint /app/llama-swap "$llama_swap_image" -config /app/config.yaml -listen 127.0.0.1:8480 || return 1
  # The first call starts the model's command, so it's made here and not inside a race.
  for _ in $(seq 1 100); do
    curl -fsS -m 10 -o /dev/null -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:8480/v1/chat/completions 2>/dev/null && return 0
    sleep 0.2
  done
  return 0
}
llama_swap_url() { echo http://127.0.0.1:8480; }
llama_swap_skip() { echo "fallback cache"; }
llama_swap_features() { echo "starts a model's server on demand and passes calls on, in OpenAI's and Anthropic's formats. No key check"; }
