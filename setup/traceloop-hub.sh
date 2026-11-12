# Traceloop Hub, from its own official image, in its YAML mode: one provider of OpenAI's type whose base URL is
# the stand-in, one model, and one chat pipeline that routes to it.
traceloop_hub_kind=container
traceloop_hub_image=docker.io/traceloop/hub:latest
traceloop_hub_title() { echo "Traceloop Hub"; }
traceloop_hub_install() {
  "$CONTAINER" pull -q "$traceloop_hub_image" > /dev/null
  version traceloop-hub "$(image_version "$traceloop_hub_image")"
}
traceloop_hub_start() { # MODE
  mkdir -p run/traceloop-hub
  cat > run/traceloop-hub/config.yaml <<'YAML'
providers:
  - key: standin
    type: openai
    api_key: sk-standin
    base_url: http://127.0.0.1:9000/v1
models:
  - key: mock
    type: mock
    provider: standin
pipelines:
  - name: default
    type: chat
    plugins:
      - model-router:
          models: [mock]
YAML
  container_up traceloop-hub 3000 -e PORT=3000 -v "$(mount_of run/traceloop-hub/config.yaml /app/config.yaml)" "$traceloop_hub_image"
}
traceloop_hub_url() { echo http://127.0.0.1:3000; }
traceloop_hub_chat_path() { echo /api/v1/chat/completions; }
traceloop_hub_skip() { echo "messages fallback cache"; }
traceloop_hub_features() { echo "routes by model through a pipeline, takes OpenAI's format. No key check, tracing off"; }
