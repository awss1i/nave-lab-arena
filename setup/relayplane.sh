# RelayPlane, its npm package's proxy, started by its own command in a home folder under run. Its settings for
# each provider's address point OpenAI's and Anthropic's at the stand-in, and a call names a real model
# (gpt-4o-mini), since it routes by model name and prices from its own table. Its routing by complexity is on, as
# it ships, its telemetry is off, as it ships, and its anonymous pings are switched off. It passes the caller's key on to the provider.
relayplane_kind=process
relayplane_title() { echo RelayPlane; }
relayplane_install() {
  local d="$ARENA_TOOLS/relayplane"
  [ -x "$d/node_modules/.bin/relayplane" ] || { mkdir -p "$d" && npm install --prefix "$d" --no-audit --no-fund -q @relayplane/proxy > /dev/null 2>&1; }
  version relayplane "$(node -e "console.log(require('$d/node_modules/@relayplane/proxy/package.json').version)")"
}
relayplane_url() { echo http://127.0.0.1:4100; }
relayplane_start() { # MODE
  mkdir -p run/relayplane-home/.relayplane
  # Its own limiter allows 60 calls a minute for a model unless its config says more, and 10,000 a minute is the
  # most its config accepts, with up to 10,000 calls waiting. Its anonymous install and session pings are off.
  # Its response cache is on as it ships. It's switched off here except in the cache race, to match Nave's entrant,
  # whose cache is off in the other races. With it on, a plain call that follows a streamed call with the same
  # messages gets the cached stream back inside a JSON object, which no client can read as an answer.
  local cache=false; [ "${1:-}" = cache ] && cache=true
  cat > run/relayplane-home/.relayplane/config.json <<JSON
{"cache": {"enabled": $cache}, "telemetry_enabled": false, "lifecycle_enabled": false, "lifecycle_explicitly_set": true, "first_run_complete": true, "config_version": 4,
 "rateLimit": {"models": {"default": {"rpm": 10000}, "gpt-4o-mini": {"rpm": 10000}, "gpt-4o": {"rpm": 10000}, "claude-haiku-4-5": {"rpm": 10000}}, "maxQueueDepth": 10000, "queueTimeoutMs": 600000}}
JSON
  HOME="$PWD/run/relayplane-home" RELAYPLANE_OPENAI_BASE_URL=http://127.0.0.1:9000/v1 RELAYPLANE_ANTHROPIC_BASE_URL=http://127.0.0.1:9000/v1 OPENAI_API_KEY=sk-standin ANTHROPIC_API_KEY=sk-standin \
    DO_NOT_TRACK=1 UP_PORT=4100 ./up.sh relayplane "$GATEWAY_CPUS" "$ARENA_TOOLS/relayplane/node_modules/.bin/relayplane" start
}
relayplane_key() { echo sk-standin; }
# Its Anthropic path takes only Anthropic's model names.
relayplane_load_args() { if [ "${1:-}" = messages ]; then printf '%s\n' --model claude-haiku-4-5; else printf '%s\n' --model gpt-4o-mini; fi; }
relayplane_clean() { rm -rf run/relayplane-home; }
relayplane_skip() { echo fallback; }
relayplane_features() { echo "passes OpenAI's and Anthropic's formats on to the provider, routes by a complexity tier, prices every call and rolls it up by run and agent in SQLite, checks budgets. Passes the caller's key on. Its own limiter is set to the most it accepts, 10,000 calls a minute for a model. A call takes it about 150 ms from a fresh install, most of it writing the call to its trace index, run store, session store and history file as it ships"; }
