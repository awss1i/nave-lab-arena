#!/usr/bin/env bash
# Runs one group of the arena from start to finish: installs that group's competitors at their latest releases,
# writes down their versions, makes the inputs, and runs the group's races with the harness, which refuses a race
# whose entrants disagree. Usage: ./arena.sh GROUP. Groups: gateway cache client template cost config eval scan
# compress image. Everything talks to the stand-in model in bin/ and to no real provider.
set -uo pipefail
. ./lib.sh
group=$1
py_libs() {
  [ -x "$ARENA_TOOLS/py/bin/python" ] || python3 -m venv "$ARENA_TOOLS/py"
  "$ARENA_TOOLS/py/bin/python" -m pip --version > /dev/null 2>&1 || "$ARENA_TOOLS/py/bin/python" -m ensurepip > /dev/null
  "$ARENA_TOOLS/py/bin/python" -m pip install -q "$@"
  for p in "$@"; do version "$p" "$("$ARENA_TOOLS/py/bin/python" -c "import importlib.metadata as m; print(m.version('$p'))")"; done
}
node_libs() {
  mkdir -p "$ARENA_TOOLS/node"
  npm install --silent --no-audit --no-fund --prefix "$ARENA_TOOLS/node" "$@"
  for p in "$@"; do version "$p" "$(node -e "console.log(require('$ARENA_TOOLS/node/node_modules/$p/package.json').version)")"; done
}
for s in setup/*.sh; do . "$s"; done
version runner "$(nproc) CPUs, $(awk '/MemTotal/ {printf "%.0f GB", $2 / 1e6}' /proc/meminfo), $(uname -sr), $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
# How long an install took, from nothing on a fresh runner, and what it left on disk.
timed_install() { # NAME
  local t0 t1
  t0=$(date +%s%N)
  gw "$1" install
  t1=$(date +%s%N)
  measure "$1" install_s "$(awk -v ns=$((t1 - t0)) 'BEGIN { printf "%.1f", ns / 1e9 }')"
  measure "$1" install_mb "$(gw "$1" size_mb)"
}
case $group in
  gw-*)
    # One gateway against Nave, on one runner, through every kind of race in races/gen.py.
    name=${group#gw-}
    timed_install nave
    timed_install "$name"
    declare -F "${name//-/_}_clean" > /dev/null && "${name//-/_}_clean"
    version "nave, switched on" "$(gw nave features)"
    version "$name, switched on" "$(gw "$name" features)"
    [ -n "$(gw "$name" skip)" ] && version "$name, kinds of race it wasn't in" "$(gw "$name" skip)"
    ARENA_FORMAT=$(gw "$name" format); export ARENA_FORMAT
    python3 data/gen_session.py run/session.jsonl 40
    python3 races/gen.py "$name" "$(gw "$name" title)" "$(gw "$name" skip)" "$(gw nave features)" "$(gw "$name" features)" "$ARENA_FORMAT" > "run/$group.json"
    bin/race run "run/$group.json" --out "results/$group"
    exit $?;;
  gateway) nave_install; litellm_install; portkey_install; bifrost_install; bifrost_clean;;
  # Portkey's open-source gateway answers `x-portkey-cache-status: DISABLED` to a cache setting, and Bifrost's cache
  # needs a vector store, so the cache race is between the two gateways whose cache runs as installed.
  cache) nave_install; litellm_install;;
  client) nave_install; litellm_install; py_libs openai aisuite any-llm-sdk langchain-openai llm; node_libs ai @ai-sdk/openai-compatible token.js @tanstack/ai @tanstack/ai-openai @mariozechner/pi-ai;;
  template) py_libs chevron pystache; node_libs mustache;;
  cost) litellm_install; py_libs tokencost genai-prices; mkdir -p run/cost; "$ARENA_TOOLS/litellm/bin/python" clients/litellm_cost.py gen run/cost;;
  config) litellm_install; mkdir -p run/config; bin/p019 make-large run/config/large.yaml;;
  eval)
    py_libs pyyaml; node_libs promptfoo; mkdir -p run/eval; bin/p017 make run/eval 500
    # Each eval framework in an environment of its own, since their dependencies pin different versions.
    for spec in "inspect-ai inspect-ai" "deepeval deepeval" "ragas ragas langchain-community<0.4"; do
      # shellcheck disable=SC2086
      set -- $spec; pkg=$1; shift
      [ -x "$ARENA_TOOLS/eval-$pkg/bin/python" ] || python3 -m venv "$ARENA_TOOLS/eval-$pkg"
      "$ARENA_TOOLS/eval-$pkg/bin/python" -m pip --version > /dev/null 2>&1 || "$ARENA_TOOLS/eval-$pkg/bin/python" -m ensurepip > /dev/null
      "$ARENA_TOOLS/eval-$pkg/bin/python" -m pip install -q openai "$@"
      version "$pkg" "$("$ARENA_TOOLS/eval-$pkg/bin/python" -c "import importlib.metadata as m; print(m.version('$pkg'))")"
    done;;
  scan)
    gitleaks_install; mkdir -p run/guard; python3 data/gen_secrets.py run/guard; python3 data/gen_pii.py run/guard 500
    # Presidio with spaCy's small English model, and LLM Guard with CPU-only PyTorch, each in its own environment.
    python3 -m venv "$ARENA_TOOLS/guard-presidio" && "$ARENA_TOOLS/guard-presidio/bin/pip" install -q presidio-analyzer \
      https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl
    version presidio-analyzer "$("$ARENA_TOOLS/guard-presidio/bin/python" -c 'import importlib.metadata as m; print(m.version("presidio-analyzer"))')"
    # LLM Guard's pinned dependencies don't build on the newest Python, so it gets Python 3.12 through uv, and
    # pip inside its environment, which it uses to fetch a language model on first use.
    python3 -m venv "$ARENA_TOOLS/uv" && "$ARENA_TOOLS/uv/bin/pip" install -q uv
    "$ARENA_TOOLS/uv/bin/uv" venv -q --python 3.12 "$ARENA_TOOLS/guard-llm-guard"
    "$ARENA_TOOLS/uv/bin/uv" pip install -q --python "$ARENA_TOOLS/guard-llm-guard/bin/python" --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match llm-guard pip
    version llm-guard "$("$ARENA_TOOLS/guard-llm-guard/bin/python" -c 'import importlib.metadata as m; print(m.version("llm-guard"))')";;
  compress) py_libs headroom-ai tiktoken;;
  pick)
    # RouteLLM with CPU-only PyTorch, and its repo's per-prompt results for MMLU and GSM8K, which both routers score.
    python3 -m venv "$ARENA_TOOLS/pick-routellm" && "$ARENA_TOOLS/pick-routellm/bin/pip" install -q --extra-index-url https://download.pytorch.org/whl/cpu routellm
    version routellm "$("$ARENA_TOOLS/pick-routellm/bin/python" -c 'import importlib.metadata as m; print(m.version("routellm"))'), its BERT router, checkpoint routellm/bert_gpt4_augmented"
    mkdir -p run/pick
    [ -d run/pick/RouteLLM ] || { git clone -q --depth 1 --filter=blob:none --sparse https://github.com/lm-sys/RouteLLM run/pick/RouteLLM && git -C run/pick/RouteLLM sparse-checkout set routellm/evals; }
    version routellm-data "RouteLLM's repo at $(git -C run/pick/RouteLLM rev-parse --short HEAD)";;
  image)
    portkey_install; bifrost_install
    "$CONTAINER" pull -q ghcr.io/berriai/litellm:main-stable > /dev/null
    version litellm-image "$("$CONTAINER" image inspect ghcr.io/berriai/litellm:main-stable --format 'created {{.Created}}') (image ghcr.io/berriai/litellm:main-stable)"
    "$CONTAINER" build -q -t localhost/nave-arena-gateway:latest -f Containerfile . > /dev/null;;
  *) echo "no group $group" >&2; exit 2;;
esac
bin/race run "races/$group.json" --out "results/$group"
