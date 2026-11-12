# Nave's gateway prototype, a static binary in bin/, with a loop on each CPU it's given.
nave_kind=process
# On a runner the install is what a user's would be: one file fetched from the repo, checked against the copy here.
nave_install() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$GITHUB_SHA/bin/p006-formats" -o run/nave-download && cmp -s run/nave-download bin/p006-formats || echo "the downloaded gateway differs from the repo's" >&2
  fi
  version nave "prototype P006, $(sha256sum bin/p006-formats | cut -c1-12)"
}
nave_start() { # MODE
  local route=mock=openai:http://127.0.0.1:9000/v1 cache=
  [ "${1:-}" = fallback ] && route="mock=openai:http://127.0.0.1:9001/v1|openai:http://127.0.0.1:9000/v1"
  [ "${1:-}" = cache ] && cache=--cache
  UP_PORT=4000 ./up.sh nave "$GATEWAY_CPUS" bin/p006-formats --listen 127.0.0.1:4000 --cpus "$GATEWAY_CPUS" --route "$route" $cache
}
nave_url() { echo http://127.0.0.1:4000; }
nave_features() { echo "routes by model, falls back, takes OpenAI's and Anthropic's formats, keeps spend by key. No key check, no request log, no limits"; }
nave_title() { echo Nave; }
nave_size_mb() { awk -v b="$(stat -c %s bin/p006-formats)" 'BEGIN { printf "%.1f", b / 1e6 }'; }
