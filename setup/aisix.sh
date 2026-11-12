# AISIX, from its own official image, set up from one declarative file: a provider key of OpenAI's kind whose
# address is the stand-in, the model "mock", and the caller's key, which it requires.
aisix_kind=container
aisix_image=ghcr.io/api7/aisix:latest
aisix_title() { echo AISIX; }
aisix_install() {
  "$CONTAINER" pull -q "$aisix_image" > /dev/null
  version aisix "$(image_version "$aisix_image")"
}
aisix_start() { # MODE
  mkdir -p run/aisix
  cat > run/aisix/config.yaml <<'YAML'
resources_file: /etc/aisix/resources.yaml
proxy:
  addr: "127.0.0.1:3100"
admin:
  enabled: false
YAML
  cat > run/aisix/resources.yaml <<'YAML'
_format_version: "1"
provider_keys:
  - display_name: standin
    provider: openai
    api_key: sk-standin
    api_base: http://127.0.0.1:9000/v1
models:
  - display_name: mock
    provider: openai
    model_name: mock
    provider_key: standin
api_keys:
  - display_name: arena
    key_env: CALLER_API_KEY
    allowed_models: ["mock"]
YAML
  container_up aisix 3100 -e CALLER_API_KEY="$LLM_KEY" -v "$(mount_of run/aisix/config.yaml /etc/aisix/config.yaml)" -v "$(mount_of run/aisix/resources.yaml /etc/aisix/resources.yaml)" "$aisix_image"
}
aisix_url() { echo http://127.0.0.1:3100; }
aisix_skip() { echo "fallback cache"; }
aisix_features() { echo "routes by model, takes OpenAI's and Anthropic's formats, checks the caller's key. Metrics off"; }
