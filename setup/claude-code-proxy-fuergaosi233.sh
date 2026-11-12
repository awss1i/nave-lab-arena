# claude-code-proxy (fuergaosi233), from its repo at its latest commit, since it publishes no image or package:
# its requirements go into a virtual environment and it's started with its own start script. It takes Anthropic's
# format and sends OpenAI's upstream, with every Claude model mapped to the stand-in's "mock". Its whole job runs
# in Anthropic's format.
claude_code_proxy_fuergaosi233_kind=process
claude_code_proxy_fuergaosi233_title() { echo "claude-code-proxy (fuergaosi233)"; }
claude_code_proxy_fuergaosi233_install() {
  local dir="$ARENA_TOOLS/claude-code-proxy-fuergaosi233"
  if [ ! -x "$dir/venv/bin/python" ]; then
    mkdir -p "$dir"
    git clone -q --depth 1 https://github.com/fuergaosi233/claude-code-proxy "$dir/src"
    python3 -m venv "$dir/venv"
    "$dir/venv/bin/pip" install -q --upgrade pip
    "$dir/venv/bin/pip" install -q -r "$dir/src/requirements.txt"
  fi
  version claude-code-proxy-fuergaosi233 "commit $(git -C "$dir/src" rev-parse --short HEAD)"
}
claude_code_proxy_fuergaosi233_start() { # MODE
  local dir="$ARENA_TOOLS/claude-code-proxy-fuergaosi233"
  OPENAI_API_KEY=sk-standin OPENAI_BASE_URL=http://127.0.0.1:9000/v1 BIG_MODEL=mock MIDDLE_MODEL=mock SMALL_MODEL=mock HOST=127.0.0.1 PORT=8083 LOG_LEVEL=ERROR \
    UP_PORT=8083 ./up.sh claude-code-proxy-fuergaosi233 "$GATEWAY_CPUS" "$dir/venv/bin/python" "$dir/src/start_proxy.py"
}
claude_code_proxy_fuergaosi233_url() { echo http://127.0.0.1:8083; }
claude_code_proxy_fuergaosi233_format() { echo messages; }
claude_code_proxy_fuergaosi233_load_args() { printf '%s\n' --model claude-3-5-haiku-20241022; }
claude_code_proxy_fuergaosi233_skip() { echo "fallback cache"; }
claude_code_proxy_fuergaosi233_features() { echo "takes Anthropic's format and sends OpenAI's upstream. No key check"; }
