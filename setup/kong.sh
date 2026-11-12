# Kong Gateway, from its own official image, with no database, set up from one declarative file: a route for
# chat completions with its ai-proxy plugin, whose provider is OpenAI's kind at the stand-in's address. It runs
# one worker process for each CPU it's given, with its access log off.
kong_kind=container
kong_image=docker.io/kong/kong:latest
kong_title() { echo Kong; }
kong_install() {
  "$CONTAINER" pull -q "$kong_image" > /dev/null
  version kong "$("$CONTAINER" run --rm "$kong_image" kong version 2>/dev/null | head -1) (image $kong_image)"
}
kong_start() { # MODE
  mkdir -p run/kong
  cat > run/kong/kong.yml <<'YAML'
_format_version: "3.0"
services:
  - name: standin
    url: http://127.0.0.1:9000
    routes:
      - name: chat
        paths: ["/v1/chat/completions"]
        strip_path: false
        plugins:
          - name: ai-proxy
            config:
              route_type: llm/v1/chat
              response_streaming: allow
              auth:
                header_name: Authorization
                header_value: Bearer sk-standin
              model:
                provider: openai
                name: mock
                options:
                  upstream_url: http://127.0.0.1:9000/v1/chat/completions
YAML
  PODMAN_USER= container_up kong 8200 -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/kong/kong.yml -e KONG_PROXY_LISTEN=127.0.0.1:8200 -e KONG_ADMIN_LISTEN=off \
    -e KONG_PROXY_ACCESS_LOG=off -e KONG_LOG_LEVEL=error -e KONG_NGINX_WORKER_PROCESSES="$(echo "$GATEWAY_CPUS" | tr ',' '\n' | wc -l)" -v "$(mount_of run/kong/kong.yml /kong/kong.yml)" "$kong_image"
}
kong_url() { echo http://127.0.0.1:8200; }
kong_skip() { echo "messages fallback cache"; }
kong_features() { echo "routes one path through its ai-proxy plugin, takes OpenAI's format. No key check, access log off"; }
