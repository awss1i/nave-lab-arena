# Helicone's AI gateway, from its own official image, with its OpenAI provider's base URL set to the stand-in the
# way its own load test sets it to a mock, and "mock" added to that provider's models. Its sign-in to Helicone's
# cloud is off, and its telemetry is at errors only.
helicone_ai_gateway_kind=container
helicone_ai_gateway_image=docker.io/helicone/ai-gateway:latest
helicone_ai_gateway_title() { echo "Helicone AI Gateway"; }
helicone_ai_gateway_install() {
  "$CONTAINER" pull -q "$helicone_ai_gateway_image" > /dev/null
  version helicone-ai-gateway "$(image_version "$helicone_ai_gateway_image")"
}
helicone_ai_gateway_start() { # MODE
  mkdir -p run/helicone-ai-gateway
  cat > run/helicone-ai-gateway/config.yaml <<'YAML'
providers:
  openai:
    base-url: "http://127.0.0.1:9000"
    models: ["mock"]
helicone:
  features: none
telemetry:
  level: error
server:
  address: 127.0.0.1
  port: 8080
YAML
  container_up helicone-ai-gateway 8080 -e OPENAI_API_KEY=sk-standin -v "$(mount_of run/helicone-ai-gateway/config.yaml /app/config.yaml)" "$helicone_ai_gateway_image" /usr/local/bin/ai-gateway --config /app/config.yaml
}
helicone_ai_gateway_url() { echo http://127.0.0.1:8080; }
helicone_ai_gateway_chat_path() { echo /ai/chat/completions; }
helicone_ai_gateway_load_args() { printf '%s\n' --model openai/mock; }
helicone_ai_gateway_skip() { echo "messages fallback cache"; }
helicone_ai_gateway_features() { echo "routes by provider and model, takes OpenAI's format. No key check, no log sent to Helicone"; }
