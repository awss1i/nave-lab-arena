# Otari, from its own official image, with PostgreSQL as its compose file runs it, the stand-in as its OpenAI
# provider's address, and a price for the model, which it requires. Callers send an API key made with its master key. PostgreSQL runs
# on the gateway's CPUs and its memory and CPU time count as Otari's.
otari_kind=container
otari_image=docker.io/mzdotai/otari:latest
otari_title() { echo Otari; }
otari_install() {
  "$CONTAINER" pull -q "$otari_image" > /dev/null
  version otari "$("$CONTAINER" image inspect "$otari_image" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^OTARI_VERSION=//p') (image $otari_image)"
}
otari_start() { # MODE
  "$CONTAINER" container inspect arena-postgres > /dev/null 2>&1 || postgres_up || return 1
  mkdir -p run/otari
  cat > run/otari/config.yml <<'YAML'
database_url: "postgresql://arena:arena@127.0.0.1:5442/arena"
host: "127.0.0.1"
port: 8100
default_pricing: true
require_pricing: true
providers:
  openai:
    api_key: sk-standin
    api_base: "http://127.0.0.1:9000/v1"
    max_retries: 0
pricing:
  openai:mock:
    input_price_per_million: 1.00
    output_price_per_million: 2.00
YAML
  container_up otari 8100 -e OTARI_MASTER_KEY="$LLM_KEY" -e OTARI_HOST=127.0.0.1 -e OTARI_PORT=8100 -e OTARI_CONFIG=/app/config.yml -v "$(mount_of run/otari/config.yml /app/config.yml)" "$otari_image" otari serve --config /app/config.yml --log-level ERROR || return 1
  # Applications call it with an API key, made once with the master key and kept in PostgreSQL.
  [ -s run/otari.key ] && return 0
  for _ in $(seq 1 100); do
    curl -fsS -m 10 -H "authorization: Bearer $LLM_KEY" -H 'content-type: application/json' -d '{"key_name":"arena"}' http://127.0.0.1:8100/api/v1/keys 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["key"])' > run/otari.key 2>/dev/null && [ -s run/otari.key ] && return 0
    sleep 0.2
  done
  echo "Otari didn't make an API key" >&2; return 1
}
otari_key() { cat run/otari.key; }
otari_url() { echo http://127.0.0.1:8100; }
otari_chat_path() { echo /api/v1/chat/completions; }
otari_messages_path() { echo /api/v1/messages; }
otari_load_args() { printf '%s\n' --model openai:mock; }
otari_stop() { container_down otari; }
otari_clean() { container_down postgres; rm -f run/otari.key; }
otari_mb() { containers_mb otari postgres; }
otari_cpu_us() { containers_cpu_us otari postgres; }
otari_skip() { echo "fallback cache"; }
otari_features() { echo "routes by provider and model, takes OpenAI's and Anthropic's formats, checks the caller's key, prices each call, records usage in PostgreSQL"; }
