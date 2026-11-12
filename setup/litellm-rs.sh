# litellm-rs, from its own official image at its latest release, with its development config (no keys, no auth,
# no database) and one provider of OpenAI's type whose base URL is the stand-in. `endpoint_access: private_network`
# is its setting for a provider on a local address, and the model "mock" is given a model from its catalog to
# take its capabilities from, which it requires before it routes a model it doesn't know. The provider's limits on calls a minute and calls at once are
# raised out of the way of the load.
litellm_rs_kind=container
litellm_rs_image=ghcr.io/majiayu000/litellm-rs:0.10.1
litellm_rs_title() { echo litellm-rs; }
litellm_rs_install() {
  "$CONTAINER" pull -q "$litellm_rs_image" > /dev/null
  version litellm-rs "$(image_version "$litellm_rs_image")"
}
litellm_rs_start() { # MODE
  mkdir -p run/litellm-rs
  cat > run/litellm-rs/gateway.yaml <<'YAML'
schema_version: "1.0"
server:
  host: "127.0.0.1"
  port: 8090
  dev_mode: true
  cors:
    enabled: false
providers:
  - name: "standin"
    provider_type: "openai"
    api_key: "sk-standin"
    base_url: "http://127.0.0.1:9000/v1"
    endpoint_access: private_network
    weight: 1.0
    rpm: 4000000000
    tpm: 4000000000
    max_concurrent_requests: 100000
    timeout: 300
    max_retries: 0
    models:
      - "mock"
    settings:
      model_identity_mappings:
        mock:
          capability_catalog_model: "gpt-4o-mini"
    enabled: true
router:
  strategy: "round_robin"
  circuit_breaker:
    failure_threshold: 5
    recovery_timeout: 60
    min_requests: 10
    success_threshold: 3
  load_balancer:
    health_check_enabled: false
    sticky_sessions: false
    session_timeout: 3600
storage:
  database:
    url: "postgresql://localhost/litellm"
    max_connections: 10
    connection_timeout: 5
    ssl: false
    enabled: false
    auto_migrate: false
  redis:
    url: "redis://localhost:6379"
    enabled: false
    max_connections: 20
    connection_timeout: 5
    cluster: false
  vector_db: null
auth:
  enable_jwt: false
  enable_api_key: false
  allow_anonymous: true
  jwt_secret: ""
  jwt_expiration: 86400
  api_key_header: "Authorization"
  rbac:
    enabled: false
    default_role: "user"
    admin_roles: ["admin", "superuser"]
monitoring:
  metrics:
    enabled: false
    port: 9090
    path: "/metrics"
    interval_seconds: 15
  tracing:
    enabled: false
    endpoint: null
    service_name: "litellm-rs-arena"
    sampling_rate: 0.1
    jaeger: null
  health:
    path: "/health"
    detailed: true
  logging: null
cache:
  enabled: false
  ttl: 3600
  max_size: 1000
pricing:
  source: "embedded://model_prices_extended"
  allow_degraded: false
  unpriced_model_policy: allow_unpriced
  unpriced_fallback_cost_per_1k_tokens: 0.0
rate_limit:
  enabled: false
  strategy: token_bucket
  default_rpm: 1000
YAML
  container_up litellm-rs 8090 -v "$(mount_of run/litellm-rs/gateway.yaml /app/config/gateway.yaml)" "$litellm_rs_image"
}
litellm_rs_url() { echo http://127.0.0.1:8090; }
# Its `/v1/messages` answers "Model 'mock' does not support capability ChatCompletion" for a model on a provider
# of OpenAI's type.
litellm_rs_skip() { echo "messages fallback cache"; }
litellm_rs_features() { echo "routes by model, takes OpenAI's format. No key check, no database, cache and rate limits off"; }
