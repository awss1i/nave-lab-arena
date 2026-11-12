# LiteLLM's proxy, the latest release from PyPI, at the settings its own production notes give: workers for every CPU
# it has, logging at errors only, and no callbacks. It routes the model "mock" to the stand-in and nowhere else.
litellm_install() {
  if [ ! -x "$ARENA_TOOLS/litellm/bin/litellm" ]; then
    python3 -m venv "$ARENA_TOOLS/litellm"
    "$ARENA_TOOLS/litellm/bin/pip" install -q --upgrade pip
    "$ARENA_TOOLS/litellm/bin/pip" install -q 'litellm[proxy]'
  fi
  version litellm "$("$ARENA_TOOLS/litellm/bin/python" -c 'import importlib.metadata as m; print(m.version("litellm"))')"
}

litellm_start() { # PORT [cache]
  {
    printf 'model_list:\n  - model_name: mock\n    litellm_params:\n      model: openai/mock\n      api_base: http://127.0.0.1:9000/v1\n      api_key: sk-standin\n'
    printf 'litellm_settings:\n  num_retries: 0\n  request_timeout: 600\n  telemetry: false\n  set_verbose: false\n'
    [ "${2:-}" = cache ] && printf '  cache: true\n  cache_params:\n    type: local\n'
    # LiteLLM won't start without a master key. Callers send this one, which the load tool reads from LLM_KEY.
    printf 'general_settings:\n  master_key: %s\n' "$LLM_KEY"
  } > run/litellm.yaml
  LITELLM_LOCAL_MODEL_COST_MAP=True LITELLM_LOG=ERROR LITELLM_MODE=PRODUCTION UP_PORT=$1 ./up.sh litellm "$GATEWAY_CPUS" \
    "$ARENA_TOOLS/litellm/bin/litellm" --config run/litellm.yaml --host 127.0.0.1 --port "$1" --num_workers "$(echo "$GATEWAY_CPUS" | tr ',' '\n' | wc -l)"
}
litellm_stop() { ./down.sh litellm; }
litellm_mb() { now_mb litellm; }
