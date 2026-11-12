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
  container_up gomodel 8080 -e PORT=8080 -e OPENAI_API_KEY=sk-standin -e OPENAI_BASE_URL=http://127.0.0.1:9000/v1 -e LOGGING_ENABLED=false -e LOG_LEVEL=error "$gomodel_image"
}
gomodel_url() { echo http://127.0.0.1:8080; }
gomodel_skip() { echo "fallback cache"; }
gomodel_features() { echo "routes by model, takes OpenAI's and Anthropic's formats, tracks usage. No key check, audit log off"; }
