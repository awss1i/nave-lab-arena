#!/usr/bin/env bash
# Starts or stops a model picker that runs as a server, for the picker race.
# Usage: clients/pick_servers.sh up|down plano|vllm-sr
# plano: its router model, Arch-Router 1.5B, served by llama.cpp's server from a container, and Plano itself
# started by its own command with the one routing preference its routing demo uses for its stronger model.
# vllm-sr: vLLM's semantic-router started by its own command from its Knowledge recipe at the released version.
# Each keeps its home folder under the arena's tools.
. ./lib.sh
what=$1 tool=$2
# Both races use one start of a server: a start finds it already answering and leaves it, and it's stopped when the
# job ends, since vLLM's semantic-router doesn't come back up cleanly after its own stop.
if [ "$what" = up ]; then
  case $tool in
    plano) curl -fsS -m 60 -o /dev/null -H 'content-type: application/json' -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:12000/routing/v1/chat/completions 2> /dev/null && exit 0;;
    vllm-sr) curl -fsS -m 5 -o /dev/null http://127.0.0.1:8080/health 2> /dev/null && exit 0;;
  esac
fi
case $tool.$what in
  plano.up)
    d="$ARENA_TOOLS/pick-plano"; mkdir -p "$d/work" "$d/home"
    # Rootless podman can't set a container's CPUs, so there the command that starts it is kept to them.
    if [ "$(basename "$CONTAINER")" = podman ]; then run="taskset -c $GATEWAY_CPUS podman run"; else run="docker run --cpuset-cpus $GATEWAY_CPUS"; fi
    $run -d --rm --name arena-arch-router --network host --entrypoint /app/llama-server -v "$ARENA_TOOLS/models/arch-router:/models$([ "$(basename "$CONTAINER")" = podman ] && echo :Z)" \
      ghcr.io/mostlygeek/llama-swap:cpu -m /models/Arch-Router-1.5B-Q4_K_M.gguf --host 127.0.0.1 --port 11500 -t 2 --alias "hf.co/katanemo/Arch-Router-1.5B.gguf:Q4_K_M" > /dev/null || exit 1
    for _ in $(seq 1 600); do curl -fsS -m 2 -o /dev/null http://127.0.0.1:11500/v1/models 2>/dev/null && break; sleep 0.2; done
    cat > "$d/work/config.yaml" <<'YAML'
version: v0.4.0

overrides:
  llm_routing_model: plano/hf.co/katanemo/Arch-Router-1.5B.gguf:Q4_K_M

listeners:
  - type: model
    name: model_listener
    port: 12000

model_providers:
  - model: plano/hf.co/katanemo/Arch-Router-1.5B.gguf:Q4_K_M
    base_url: http://localhost:11500

  - model: openai/gpt-4o-mini
    access_key: $OPENAI_API_KEY
    default: true

  - model: openai/gpt-4o
    access_key: $OPENAI_API_KEY

routing_preferences:
  - name: complex_reasoning
    description: complex reasoning tasks, multi-step analysis, or detailed explanations
    models:
      - openai/gpt-4o
      - openai/gpt-4o-mini
YAML
    (cd "$d/work" && HOME="$d/home" OPENAI_API_KEY=sk-standin DO_NOT_TRACK=1 taskset -c "$GATEWAY_CPUS" "$d/bin/planoai" up config.yaml > "$d/up.log" 2>&1) || { echo "Plano didn't start: $(tail -3 "$d/up.log")" >&2; exit 1; }
    for _ in $(seq 1 300); do curl -fsS -m 60 -o /dev/null -H 'content-type: application/json' -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:12000/routing/v1/chat/completions 2>/dev/null && exit 0; sleep 0.5; done
    echo "Plano never gave a routing decision" >&2; exit 1;;
  plano.down)
    d="$ARENA_TOOLS/pick-plano"
    (cd "$d/work" && HOME="$d/home" "$d/bin/planoai" down > /dev/null 2>&1)
    "$CONTAINER" kill arena-arch-router > /dev/null 2>&1 || true;;
  vllm-sr.up)
    d="$ARENA_TOOLS/pick-vllm-sr"; mkdir -p "$d/work" "$d/home"
    rm -rf "$d/work/knowledge" && cp -r "$ARENA_TOOLS/src/vllm-sr-v04/config/recipes/knowledge" "$d/work/" || exit 1
    # The recipe's model addresses are examples. The preview that's asked for a decision never calls them.
    sed -i 's/endpoint: vllm-omni:8000/endpoint: host.docker.internal:9000/; s/endpoint: vllm:8000/endpoint: host.docker.internal:9000/' "$d/work/knowledge/config.yaml"
    (cd "$d/work/knowledge" && HOME="$d/home" HF_HOME="$ARENA_TOOLS/models" DO_NOT_TRACK=1 "$d/bin/vllm-sr" serve --config config.yaml --minimal --envoy-image docker.io/envoyproxy/envoy:v1.35.3 --startup-timeout 1500 > "$d/serve.log" 2>&1) \
      || { echo "vLLM's semantic-router didn't start: $(tail -3 "$d/serve.log")" >&2; exit 1; }
    for _ in $(seq 1 600); do curl -fsS -m 5 -o /dev/null http://127.0.0.1:8080/health 2>/dev/null && exit 0; sleep 0.5; done
    echo "vLLM's semantic-router never answered" >&2; exit 1;;
  vllm-sr.down)
    d="$ARENA_TOOLS/pick-vllm-sr"
    (cd "$d/work/knowledge" 2> /dev/null && HOME="$d/home" "$d/bin/vllm-sr" stop > /dev/null 2>&1) || true;;
  *) echo "usage: pick_servers.sh up|down plano|vllm-sr" >&2; exit 2;;
esac
