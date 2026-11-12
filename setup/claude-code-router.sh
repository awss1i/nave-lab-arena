# Claude Code Router, its npm package's command, which starts the same gateway as its desktop app. Its settings
# live in a SQLite file in its home folder and are meant to be made in its management page, so here its first
# start makes the file, and the stand-in is written into the file's settings as a provider before the real start.
# Its home is a folder under run, never the user's. It checks the caller's key, which it made itself.
claude_code_router_kind=process
claude_code_router_title() { echo "Claude Code Router"; }
claude_code_router_install() {
  local dir="$ARENA_TOOLS/claude-code-router"
  [ -x "$dir/node_modules/.bin/ccr" ] || { mkdir -p "$dir" && npm install --prefix "$dir" --no-audit --no-fund -q @musistudio/claude-code-router > /dev/null 2>&1; }
  version claude-code-router "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$dir/node_modules/@musistudio/claude-code-router/package.json")"
}
claude_code_router_start() { # MODE
  local home="$PWD/run/claude-code-router/home" ccr="$ARENA_TOOLS/claude-code-router/node_modules/.bin/ccr" db
  db="$home/.claude-code-router/config.sqlite"
  if [ ! -s "$db.key" ]; then
    mkdir -p "$home"
    HOME="$home" UP_PORT=3458 ./up.sh claude-code-router "$GATEWAY_CPUS" "$ccr" serve --no-open --host 127.0.0.1 || return 1
    for _ in $(seq 1 200); do
      python3 -c 'import sqlite3, sys; sys.exit(0 if sqlite3.connect(sys.argv[1]).execute("select count(*) from api_keys").fetchone()[0] else 1)' "$db" 2>/dev/null && break
      sleep 0.1
    done
    ./down.sh claude-code-router
  fi
  python3 - "$db" "${1:-}" <<'PY' || return 1
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
config = json.loads(db.execute("select value_json from app_config where key='default'").fetchone()[0])
provider = lambda name, port: {"name": name, "api_base_url": f"http://127.0.0.1:{port}/v1/chat/completions", "api_key": "sk-standin", "models": ["mock"]}
config["Providers"] = [provider("standin", 9000)]
config["Router"]["default"] = "standin,mock"
config["Router"]["fallback"] = {"mode": "off", "models": [], "retryCount": 1}
if sys.argv[2] == "fallback":
    config["Providers"].insert(0, provider("failing", 9001))
    config["Router"]["default"] = "failing,mock"
    config["Router"]["fallback"] = {"mode": "models", "models": ["standin,mock"], "retryCount": 1}
db.execute("update app_config set value_json=? where key='default'", (json.dumps(config),))
db.commit()
print(db.execute("select encrypted_key from api_keys").fetchone()[0], file=open(sys.argv[1] + ".key", "w"))
PY
  HOME="$home" UP_PORT=3456 ./up.sh claude-code-router "$GATEWAY_CPUS" "$ccr" serve --no-open --host 127.0.0.1
}
claude_code_router_url() { echo http://127.0.0.1:3456; }
claude_code_router_key() { cat run/claude-code-router/home/.claude-code-router/config.sqlite.key; }
claude_code_router_clean() { rm -rf run/claude-code-router; }
claude_code_router_skip() { echo cache; }
claude_code_router_features() { echo "routes by rule to a provider and model, falls back to listed models, takes OpenAI's and Anthropic's formats, checks the caller's key. Request logs off, as it ships"; }
