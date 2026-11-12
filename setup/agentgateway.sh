# agentgateway, from its own official image, set up from one file the way its llm-basic example is: the model
# "mock" on a provider of OpenAI's kind whose base URL is the stand-in.
agentgateway_kind=container
agentgateway_image=ghcr.io/agentgateway/agentgateway:latest
agentgateway_title() { echo agentgateway; }
agentgateway_install() {
  "$CONTAINER" pull -q "$agentgateway_image" > /dev/null
  version agentgateway "$(image_version "$agentgateway_image")"
}
agentgateway_start() { # MODE
  mkdir -p run/agentgateway
  cat > run/agentgateway/config.yaml <<'YAML'
config:
  readinessAddr: 127.0.0.1:19001
  statsAddr: 127.0.0.1:19002
frontendPolicies:
  http:
    maxBufferSize: 20971520
llm:
  port: 4400
  models:
    - name: mock
      provider: openAI
      params:
        model: mock
        apiKey: sk-standin
        baseUrl: http://127.0.0.1:9000/v1
YAML
  PODMAN_USER= container_up agentgateway 4400 -v "$(mount_of run/agentgateway/config.yaml /config.yaml)" "$agentgateway_image" -f /config.yaml
}
agentgateway_url() { echo http://127.0.0.1:4400; }
agentgateway_skip() { echo "fallback cache"; }
agentgateway_features() { echo "routes by model, takes OpenAI's and Anthropic's formats. No key check"; }
