# Apache APISIX, from its own official image, in its standalone mode with no etcd, set up from one file: a route
# for chat completions with its ai-proxy plugin, whose provider is the OpenAI-compatible kind at the stand-in's
# address. It runs one worker process for each CPU it's given, with its access log off.
apisix_kind=container
apisix_image=docker.io/apache/apisix:latest
apisix_title() { echo APISIX; }
apisix_install() {
  "$CONTAINER" pull -q "$apisix_image" > /dev/null
  version apisix "$("$CONTAINER" run --rm --entrypoint apisix "$apisix_image" version 2>/dev/null | tail -1) (image $apisix_image)"
}
apisix_start() { # MODE
  mkdir -p run/apisix
  cat > run/apisix/config.yaml <<YAML
apisix:
  node_listen:
    - ip: 127.0.0.1
      port: 8300
  enable_admin: false
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
nginx_config:
  worker_processes: $(echo "$GATEWAY_CPUS" | tr ',' '\n' | wc -l)
  error_log_level: error
  http:
    enable_access_log: false
YAML
  cat > run/apisix/apisix.yaml <<'YAML'
routes:
  - id: chat
    uri: /v1/chat/completions
    plugins:
      ai-proxy:
        provider: openai-compatible
        auth:
          header:
            Authorization: Bearer sk-standin
        options:
          model: mock
        override:
          endpoint: http://127.0.0.1:9000/v1/chat/completions
#END
YAML
  PODMAN_USER= container_up apisix 8300 -v "$(mount_of run/apisix/config.yaml /usr/local/apisix/conf/config.yaml)" -v "$(mount_of run/apisix/apisix.yaml /usr/local/apisix/conf/apisix.yaml)" "$apisix_image"
}
apisix_url() { echo http://127.0.0.1:8300; }
apisix_skip() { echo "messages fallback cache"; }
apisix_features() { echo "routes one path through its ai-proxy plugin, takes OpenAI's format. No key check, access log off"; }
