# Tyk Gateway, the open-source one, from its own official image, with Redis, which it needs to start. It's set up
# from files: one keyless API that passes /v1/ on to the stand-in. Its analytics are off. Redis runs on the
# gateway's CPUs and its memory and CPU time count as Tyk's.
tyk_kind=container
tyk_image=docker.io/tykio/tyk-gateway:latest
tyk_title() { echo Tyk; }
tyk_install() {
  "$CONTAINER" pull -q "$tyk_image" > /dev/null
  "$CONTAINER" pull -q docker.io/library/redis:8 > /dev/null
  version tyk "$(image_version "$tyk_image")"
}
tyk_start() { # MODE
  "$CONTAINER" container inspect arena-redis > /dev/null 2>&1 || redis_up || return 1
  mkdir -p run/tyk/apps && chmod -R 777 run/tyk
  cat > run/tyk/tyk.conf <<'JSON'
{
  "listen_address": "127.0.0.1",
  "listen_port": 8400,
  "secret": "arena-tyk-secret",
  "template_path": "/opt/tyk-gateway/templates",
  "use_db_app_configs": false,
  "app_path": "/opt/tyk-gateway/apps",
  "middleware_path": "/opt/tyk-gateway/middleware",
  "storage": { "type": "redis", "host": "127.0.0.1", "port": 6389, "optimisation_max_idle": 2000, "optimisation_max_active": 4000 },
  "enable_analytics": false,
  "allow_insecure_configs": true,
  "policies": { "policy_source": "file", "policy_path": "/opt/tyk-gateway/policies" },
  "log_level": "error",
  "close_connections": false,
  "max_idle_connections_per_host": 500
}
JSON
  cat > run/tyk/apps/standin.json <<'JSON'
{
  "name": "standin",
  "api_id": "standin",
  "org_id": "arena",
  "use_keyless": true,
  "active": true,
  "definition": { "location": "header", "key": "x-api-version" },
  "version_data": { "not_versioned": true, "versions": { "Default": { "name": "Default", "use_extended_paths": true } } },
  "proxy": { "listen_path": "/v1/", "target_url": "http://127.0.0.1:9000/v1/", "strip_listen_path": true }
}
JSON
  PODMAN_USER= container_up tyk 8400 -v "$(mount_of run/tyk/tyk.conf /opt/tyk-gateway/tyk.conf)" -v "$(mount_of run/tyk/apps /opt/tyk-gateway/apps)" "$tyk_image" || return 1
  # It listens before it has loaded its APIs.
  for _ in $(seq 1 100); do
    curl -fsS -m 5 -o /dev/null -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:8400/v1/chat/completions 2>/dev/null && return 0
    sleep 0.1
  done
  return 0
}
tyk_url() { echo http://127.0.0.1:8400; }
tyk_stop() { container_down tyk; }
tyk_clean() { container_down redis; }
tyk_mb() { containers_mb tyk redis; }
tyk_cpu_us() { containers_cpu_us tyk redis; }
tyk_skip() { echo "messages fallback cache"; }
tyk_features() { echo "passes one path on to the model as an API gateway, in OpenAI's format. No key check, analytics off"; }
