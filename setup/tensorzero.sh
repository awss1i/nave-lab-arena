# TensorZero's gateway, from its own official image, with one model whose provider is of OpenAI's type at the
# stand-in's address, and observability off, which is how its own latency benchmark runs it. The project is
# archived upstream, and its last image still runs.
tensorzero_kind=container
tensorzero_image=docker.io/tensorzero/gateway:latest
tensorzero_title() { echo TensorZero; }
tensorzero_install() {
  "$CONTAINER" pull -q "$tensorzero_image" > /dev/null
  version tensorzero "$(image_version "$tensorzero_image")"
}
tensorzero_start() { # MODE
  mkdir -p run/tensorzero
  cat > run/tensorzero/tensorzero.toml <<'TOML'
[gateway]
bind_address = "127.0.0.1:3200"
observability.enabled = false

[models.mock]
routing = ["standin"]

[models.mock.providers.standin]
type = "openai"
model_name = "mock"
api_base = "http://127.0.0.1:9000/v1"
api_key_location = "none"
TOML
  container_up tensorzero 3200 -v "$(mount_of run/tensorzero/tensorzero.toml /app/config/tensorzero.toml)" "$tensorzero_image" --config-file /app/config/tensorzero.toml
}
tensorzero_url() { echo http://127.0.0.1:3200; }
tensorzero_chat_path() { echo /openai/v1/chat/completions; }
tensorzero_load_args() { printf '%s\n' --model tensorzero::model_name::mock; }
tensorzero_skip() { echo "messages fallback cache"; }
tensorzero_features() { echo "routes by model, takes OpenAI's format. No key check, observability off"; }
