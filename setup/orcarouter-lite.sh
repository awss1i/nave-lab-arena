# OrcaRouter Lite, installed from its repo as its README says, since it publishes no image or package. It's built
# on LiteLLM's router. Its OpenAI provider's key and address are the stand-in's, and a call names a model from its
# catalog, gpt-4o-mini, which it sends on to that provider. It checks the caller's key, which it prints once at
# its first start. Its model "auto" picks the cheapest model that can serve a request and doesn't look at how hard
# the prompt is, so it's raced as a gateway and not in the model-picker race.
orcarouter_lite_kind=process
orcarouter_lite_title() { echo "OrcaRouter Lite"; }
orcarouter_lite_install() {
  local d="$ARENA_TOOLS/orcarouter-lite"
  if [ ! -x "$d/bin/orcarouter-lite" ]; then
    [ -d "$ARENA_TOOLS/src/orcarouter-lite" ] || git clone -q --depth 1 https://github.com/Continuum-AI-Corp/OrcaRouter-Lite "$ARENA_TOOLS/src/orcarouter-lite"
    local uv; uv=$(arena_uv)
    "$uv" venv -q --python 3.12 "$d" && "$uv" pip install -q --python "$d/bin/python" -e "$ARENA_TOOLS/src/orcarouter-lite" > /dev/null 2>&1
  fi
  version orcarouter-lite "$("$d/bin/python" -c 'import importlib.metadata as m; print(m.version("orcarouter-lite"))' 2>/dev/null) at $(git -C "$ARENA_TOOLS/src/orcarouter-lite" rev-parse --short HEAD), with LiteLLM $("$d/bin/python" -c 'import importlib.metadata as m; print(m.version("litellm"))' 2>/dev/null)"
}
orcarouter_lite_url() { echo http://127.0.0.1:8800; }
orcarouter_lite_start() { # MODE
  local d="$PWD/run/orcarouter-lite-data"
  mkdir -p "$d"
  HOME="$d" PYTHONUNBUFFERED=1 HOST=127.0.0.1 PORT=8800 LOG_LEVEL=warning LITELLM_LOCAL_MODEL_COST_MAP=True OPENAI_API_KEY=sk-standin OPENAI_API_BASE=http://127.0.0.1:9000/v1 \
    OPENAI_BASE_URL=http://127.0.0.1:9000/v1 CREDENTIAL_ENCRYPTION_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa API_KEY_PEPPER=arena-pepper \
    DATABASE_URL="sqlite+aiosqlite:///$d/orca.db" UP_PORT=8800 ./up.sh orcarouter-lite "$GATEWAY_CPUS" "$ARENA_TOOLS/orcarouter-lite/bin/orcarouter-lite" || return 1
  # The key is printed at the first start only, so it's kept beside the database it belongs to.
  [ -s "$d/key" ] || { for _ in $(seq 1 100); do grep -o 'sk-orca-[A-Za-z0-9_-]*' run/orcarouter-lite.log 2>/dev/null | tail -1 > "$d/key"; [ -s "$d/key" ] && break; sleep 0.1; done; }
  [ -s "$d/key" ] || { echo "OrcaRouter Lite didn't print its key" >&2; return 1; }
}
orcarouter_lite_key() { cat run/orcarouter-lite-data/key; }
orcarouter_lite_load_args() { printf '%s\n' --model gpt-4o-mini; }
orcarouter_lite_clean() { rm -rf run/orcarouter-lite-data; }
orcarouter_lite_skip() { echo "fallback cache"; }
orcarouter_lite_features() { echo "routes a catalog model to its provider through LiteLLM's router, takes OpenAI's and Anthropic's formats, checks the caller's key, keeps usage in SQLite"; }
