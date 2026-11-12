# CLIProxyAPI, its latest release binary. It's built to share coding subscriptions, which need a sign-in, and it
# also takes an OpenAI-compatible provider from its config file, which is how the stand-in is set here. It checks
# the caller's key against its list.
cliproxyapi_kind=process
cliproxyapi_title() { echo CLIProxyAPI; }
cliproxyapi_install() {
  local dir="$ARENA_TOOLS/cliproxyapi" tag
  if [ ! -x "$dir/cli-proxy-api" ]; then
    mkdir -p "$dir"
    tag=$(curl -fsSL -A arena https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')
    curl -fsSL "https://github.com/router-for-me/CLIProxyAPI/releases/download/$tag/CLIProxyAPI_${tag#v}_linux_amd64.tar.gz" | tar -xz -C "$dir"
    echo "$tag" > "$dir/version"
  fi
  version cliproxyapi "$(cat "$dir/version")"
}
cliproxyapi_start() { # MODE
  mkdir -p run/cliproxyapi/auth
  {
    printf 'config-version: 8\nserver:\n  host: "127.0.0.1"\n  port: 8317\n  response-compression:\n    enabled: false\n'
    printf 'management:\n  disable-control-panel: true\naccess:\n  api-keys:\n    - "sk-arena"\n'
    printf 'oauth:\n  auth-dir: "%s/run/cliproxyapi/auth"\n' "$PWD"
    printf 'api-keys:\n  openai-compatibility:\n'
    if [ "${1:-}" = fallback ]; then
      # Its pool: the same alias on two upstream names, and a call that fails before any output goes on to the next.
      printf '    - name: "failing"\n      base-url: "http://127.0.0.1:9001/v1"\n      keys:\n        - api-key: "sk-standin"\n      models:\n        - name: "mock"\n          alias: "mock"\n'
    fi
    printf '    - name: "standin"\n      base-url: "http://127.0.0.1:9000/v1"\n      keys:\n        - api-key: "sk-standin"\n      models:\n        - name: "mock"\n          alias: "mock"\n'
  } > run/cliproxyapi/config.yaml
  UP_PORT=8317 ./up.sh cliproxyapi "$GATEWAY_CPUS" "$ARENA_TOOLS/cliproxyapi/cli-proxy-api" --local-model --config "$PWD/run/cliproxyapi/config.yaml"
}
cliproxyapi_url() { echo http://127.0.0.1:8317; }
cliproxyapi_key() { echo sk-arena; }
cliproxyapi_skip() { echo cache; }
cliproxyapi_features() { echo "routes by model alias, retries and cools down a failing credential, takes OpenAI's and Anthropic's formats, checks the caller's key. Its subscription sign-ins aren't used"; }
