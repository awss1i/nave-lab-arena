# Respan Gateway, its latest release binary, with the stand-in as an OpenAI-compatible provider and a route for
# the model "mock". With no client keys it answers on loopback without a key check, which matches Nave's entrant.
respan_gateway_kind=process
respan_gateway_title() { echo "Respan Gateway"; }
respan_gateway_install() {
  local dir="$ARENA_TOOLS/respan-gateway" tag
  if [ ! -x "$dir/respan-gateway" ]; then
    mkdir -p "$dir"
    tag=$(latest_tag respanai/respan-gateway)
    curl -fsSL "https://github.com/respanai/respan-gateway/releases/download/$tag/respan-gateway-$tag-x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C "$dir" --strip-components=1 2>/dev/null \
      || curl -fsSL "https://github.com/respanai/respan-gateway/releases/download/$tag/respan-gateway-$tag-x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C "$dir"
    [ -x "$dir/respan-gateway" ] || cp "$(find "$dir" -type f -name respan-gateway | head -1)" "$dir/respan-gateway"
  fi
  version respan-gateway "$("$dir/respan-gateway" --version 2>&1 | head -1)"
}
respan_gateway_start() { # MODE
  mkdir -p run/respan-gateway
  {
    echo 'listen = "127.0.0.1:8085"'
    printf '[providers.local]\nformats = ["openai-chat"]\nbase_url = "http://127.0.0.1:9000/v1"\n'
    if [ "${1:-}" = fallback ]; then
      printf '[providers.failing]\nformats = ["openai-chat"]\nbase_url = "http://127.0.0.1:9001/v1"\n'
      printf '[routes.mock]\nto = ["failing/mock", "local/mock"]\n'
    elif [ "${1:-}" = own ]; then
      # Its hedging, for its own benchmark: the same model through a second provider entry, raced after 100 ms.
      printf '[providers.second]\nformats = ["openai-chat"]\nbase_url = "http://127.0.0.1:9000/v1"\n'
      printf '[routes.mock]\nto = ["local/mock", "second/mock"]\nhedge = "100ms"\n'
    else
      printf '[routes.mock]\nto = "local"\n'
    fi
  } > run/respan-gateway/gateway.toml
  UP_PORT=8085 ./up.sh respan-gateway "$GATEWAY_CPUS" "$ARENA_TOOLS/respan-gateway/respan-gateway" serve --config run/respan-gateway/gateway.toml --log off
}
respan_gateway_url() { echo http://127.0.0.1:8085; }
respan_gateway_skip() { echo cache; }
respan_gateway_features() { echo "routes by model, falls back, takes OpenAI's and Anthropic's formats. No key check on loopback, request log off, tracing off"; }
# Its README's benchmark has a row for the 99th percentile when 5% of calls are slow, which its hedging answers: a
# second provider is raced when the first hasn't answered in time. Here every twentieth call takes two seconds.
respan_gateway_own_benchmark() { echo "200 4000 128|--slow-every 20 --slow-ms 2000|the slow-tail row of Respan's README table, where one call in twenty takes two seconds"; }
