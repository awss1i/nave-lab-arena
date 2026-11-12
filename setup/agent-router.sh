# Agent Router (Envoy AI Gateway), its latest release's standalone command, `aigw run`, which starts Envoy with the
# router beside it and takes its provider from the environment: OpenAI's kind at the stand-in's address.
agent_router_kind=process
agent_router_title() { echo "Agent Router"; }
agent_router_install() {
  local dir="$ARENA_TOOLS/agent-router" tag
  if [ ! -x "$dir/aigw" ]; then
    mkdir -p "$dir"
    tag=$(curl -fsSL -A arena https://api.github.com/repos/theagentrouter/agent-router/releases/latest | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')
    curl -fsSL "https://github.com/theagentrouter/agent-router/releases/download/$tag/aigw-linux-amd64" -o "$dir/aigw" && chmod +x "$dir/aigw"
    echo "$tag" > "$dir/version"
    # Its first start downloads the Envoy it runs, which belongs to the install, so it's started once here.
    agent_router_start > /dev/null 2>&1; ./down.sh agent-router
  fi
  version agent-router "$(cat "$dir/version" 2>/dev/null)"
}
agent_router_start() { # MODE
  local dir="$ARENA_TOOLS/agent-router"
  OPENAI_API_KEY=sk-standin OPENAI_BASE_URL=http://127.0.0.1:9000/v1 UP_PORT=1975 ./up.sh agent-router "$GATEWAY_CPUS" "$dir/aigw" run \
    --config-home "$dir/config" --data-home "$dir/data" --state-home "$dir/state" --runtime-dir "$dir/runtime" --run-id 0
}
agent_router_url() { echo http://127.0.0.1:1975; }
# Started this way, its `/v1/messages` answers "unsupported path".
agent_router_skip() { echo "messages fallback cache"; }
agent_router_features() { echo "routes through Envoy with its router as an external processor, takes OpenAI's format as started here. No key check"; }
