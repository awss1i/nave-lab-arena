# Olla, from its own official image, with its "olla" engine, which its docs give as the fast one, the stand-in as
# its one static endpoint of the OpenAI-compatible type, request logging off, and its rate limits lifted, since
# they default to 100 calls a minute from one address.
olla_kind=container
olla_image=ghcr.io/thushan/olla:latest
olla_title() { echo Olla; }
olla_install() {
  "$CONTAINER" pull -q "$olla_image" > /dev/null
  version olla "$(image_version "$olla_image")"
}
olla_start() { # MODE
  mkdir -p run/olla
  cat > run/olla/config.yaml <<'YAML'
server:
  host: "127.0.0.1"
  port: 40114
  read_timeout: 30s
  read_header_timeout: 10s
  write_timeout: 0s
  shutdown_timeout: 2s
  request_logging: false
  request_limits:
    max_body_size: 104857600
    max_header_size: 1048576
  rate_limits:
    global_requests_per_minute: 0
    per_ip_requests_per_minute: 0
    health_requests_per_minute: 0
    burst_size: 100000
proxy:
  engine: "olla"
  profile: "auto"
  load_balancer: "priority"
  connection_timeout: 60s
  response_timeout: 15m
  read_timeout: 10m
discovery:
  type: "static"
  refresh_interval: 30s
  static:
    endpoints:
      - url: "http://127.0.0.1:9000"
        name: "standin"
        type: "openai-compatible"
        priority: 100
        model_url: "/v1/models"
        health_check_url: "/v1/models"
        check_interval: 2s
        check_timeout: 1s
  model_discovery:
    enabled: true
    interval: 5m
    timeout: 30s
    concurrent_workers: 5
logging:
  level: "error"
  format: "json"
  output: "stdout"
YAML
  container_up olla 40114 -e OLLA_CONFIG_FILE=/app/config/arena.yaml -v "$(mount_of run/olla/config.yaml /app/config/arena.yaml)" "$olla_image" -c /app/config/arena.yaml || return 1
  # It routes only to endpoints its health check has passed, so the first call waits for that.
  for _ in $(seq 1 100); do curl -fsS -m 2 http://127.0.0.1:40114/internal/status/endpoints 2>/dev/null | grep -q '"healthy"' && return 0; sleep 0.1; done
  return 0
}
olla_url() { echo http://127.0.0.1:40114; }
olla_chat_path() { echo /olla/proxy/v1/chat/completions; }
olla_skip() { echo "messages fallback cache"; }
olla_features() { echo "balances load across endpoints and passes calls through, in OpenAI's format. No key check, request log off, rate limits lifted"; }
