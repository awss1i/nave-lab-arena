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
    python3 races/gen.py "$name" "$(gw "$name" title)" "$(gw "$name" skip)" "$(gw nave features)" "$(gw "$name" features)" "$ARENA_FORMAT" "$(gw "$name" own_benchmark)" > "run/$group.json"
    bin/race run "run/$group.json" --out "results/$group"
    exit $?;;
  gateway) nave_install; litellm_install; portkey_install; bifrost_install; bifrost_clean;;
  # Portkey's open-source gateway answers `x-portkey-cache-status: DISABLED` to a cache setting, and Bifrost's cache
  # needs a vector store, so the cache race is between the two gateways whose cache runs as installed.
  cache)
    nave_install; litellm_install
    # The cache libraries, each in an environment of its own, and Redis for the one that keeps its cache there.
    uv=$(arena_uv)
    "$uv" venv -q --python 3.11 "$ARENA_TOOLS/cache-gptcache" && "$uv" pip install -q --python "$ARENA_TOOLS/cache-gptcache/bin/python" gptcache openai onnxruntime 'numpy<2' 'transformers<4.50' 'tokenizers<0.22' faiss-cpu sqlalchemy huggingface_hub \
      || echo "GPTCache didn't install" >&2
    version gptcache "$("$ARENA_TOOLS/cache-gptcache/bin/python" -c 'import importlib.metadata as m; print(m.version("gptcache"))'), with its ONNX embedding, SQLite and FAISS"
    "$uv" venv -q --python 3.12 "$ARENA_TOOLS/cache-redisvl" && "$uv" pip install -q --python "$ARENA_TOOLS/cache-redisvl/bin/python" --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match redisvl openai sentence-transformers \
      || echo "redis-vl didn't install" >&2
    version redisvl "$("$ARENA_TOOLS/cache-redisvl/bin/python" -c 'import importlib.metadata as m; print(m.version("redisvl"))'), its SemanticCache with its default local vectorizer, on Redis 8"
    "$CONTAINER" pull -q docker.io/library/redis:8 > /dev/null
    # ModelCache at its latest tagged release, from its repo with its pinned requirements and the embedding model
    # its README says to download. Its newest commits call a Windows-only function at start and don't run on Linux.
    [ -d "$ARENA_TOOLS/src/modelcache" ] || { mkdir -p "$ARENA_TOOLS/src" && git clone -q --depth 1 --branch release-v0.2.0 https://github.com/codefuse-ai/ModelCache "$ARENA_TOOLS/src/modelcache"; }
    "$uv" venv -q --python 3.10 "$ARENA_TOOLS/cache-modelcache" && "$uv" pip install -q --python "$ARENA_TOOLS/cache-modelcache/bin/python" --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match \
      -r "$ARENA_TOOLS/src/modelcache/requirements.txt" huggingface_hub || echo "ModelCache didn't install" >&2
    HF_HOME="$ARENA_TOOLS/models" "$ARENA_TOOLS/cache-modelcache/bin/python" -c 'import sys; from huggingface_hub import snapshot_download; snapshot_download("shibing624/text2vec-base-chinese", local_dir=sys.argv[1], allow_patterns=["*.bin", "*.json", "*.txt"])' \
      "$ARENA_TOOLS/src/modelcache/model/text2vec-base-chinese" > /dev/null 2>&1 || echo "ModelCache's embedding model didn't download" >&2
    version modelcache "release-v0.2.0 at $(git -C "$ARENA_TOOLS/src/modelcache" rev-parse --short HEAD), its demo service with SQLite, FAISS and text2vec-base-chinese";;
  client)
    nave_install; litellm_install; py_libs openai aisuite any-llm-sdk langchain-openai llm; node_libs ai @ai-sdk/openai-compatible token.js @tanstack/ai @tanstack/ai-openai @mariozechner/pi-ai
    # The Rust libraries, each as a small program in clients/rust, built here at the latest versions Cargo resolves.
    (cd clients/rust && CARGO_TARGET_DIR="$ARENA_TOOLS/rust-clients" cargo build --release -q) || echo "the Rust client programs didn't build" >&2
    for b in genai rig llm; do [ -x "$ARENA_TOOLS/rust-clients/release/${b}_client" ] || { echo "the Rust client program ${b}_client is missing" >&2; exit 1; }; done
    GEM_HOME="$ARENA_TOOLS/gems" gem install -q --no-document ruby_llm > /dev/null 2>&1 || echo "ruby_llm didn't install" >&2
    version ruby_llm "$(GEM_HOME="$ARENA_TOOLS/gems" GEM_PATH="$ARENA_TOOLS/gems" gem list ruby_llm 2>/dev/null | sed -n 's/^ruby_llm (\(.*\))/\1/p')"
    for crate in genai rig-core llm; do version "$crate (Rust)" "$(cd clients/rust && cargo tree -q --depth 1 --prefix none 2>/dev/null | sed -n "s/^$crate v\([0-9.]*\).*/\1/p" | head -1)"; done;;
  template) py_libs chevron pystache; node_libs mustache;;
  cost)
    litellm_install; py_libs tokencost genai-prices; mkdir -p run/cost; "$ARENA_TOOLS/litellm/bin/python" clients/litellm_cost.py gen run/cost
    # Two price lists that are data: models.dev's api.json and Portkey's models repo.
    mkdir -p "$ARENA_TOOLS/src/prices"
    curl -fsSL -m 120 -A arena https://models.dev/api.json -o "$ARENA_TOOLS/src/prices/models-dev.json" || echo "models.dev's price list didn't download" >&2
    version models.dev "api.json fetched $(date -u +%Y-%m-%d), $(python3 -c 'import json, sys; print(sum(len(v.get("models", {})) for v in json.load(open(sys.argv[1])).values()))' "$ARENA_TOOLS/src/prices/models-dev.json") models"
    [ -d "$ARENA_TOOLS/src/prices/portkey-models" ] || git clone -q --depth 1 https://github.com/Portkey-AI/models "$ARENA_TOOLS/src/prices/portkey-models"
    version portkey-models "Portkey-AI/models at $(git -C "$ARENA_TOOLS/src/prices/portkey-models" rev-parse --short HEAD)";;
  config) litellm_install; mkdir -p run/config; bin/p019 make-large run/config/large.yaml;;
  eval)
    py_libs pyyaml; node_libs promptfoo; mkdir -p run/eval; bin/p017 make run/eval 500
    # Each eval framework in an environment of its own, since their dependencies pin different versions.
    for spec in "inspect-ai inspect-ai" "deepeval deepeval" "ragas ragas langchain-community<0.4" "autoevals autoevals"; do
      # shellcheck disable=SC2086
      set -- $spec; pkg=$1; shift
      [ -x "$ARENA_TOOLS/eval-$pkg/bin/python" ] || python3 -m venv "$ARENA_TOOLS/eval-$pkg"
      "$ARENA_TOOLS/eval-$pkg/bin/python" -m pip --version > /dev/null 2>&1 || "$ARENA_TOOLS/eval-$pkg/bin/python" -m ensurepip > /dev/null
      "$ARENA_TOOLS/eval-$pkg/bin/python" -m pip install -q openai "$@"
      version "$pkg" "$("$ARENA_TOOLS/eval-$pkg/bin/python" -c "import importlib.metadata as m; print(m.version('$pkg'))")"
    done
    # OpenAI's evals pins dependencies that no longer build, so it gets Python 3.11 through uv, itself without its
    # dependencies, and then the ones its command imports.
    python3 -m venv "$ARENA_TOOLS/uv" && "$ARENA_TOOLS/uv/bin/pip" install -q uv
    "$ARENA_TOOLS/uv/bin/uv" venv -q --python 3.11 "$ARENA_TOOLS/eval-openai-evals"
    "$ARENA_TOOLS/uv/bin/uv" pip install -q --python "$ARENA_TOOLS/eval-openai-evals/bin/python" --no-deps evals
    "$ARENA_TOOLS/uv/bin/uv" pip install -q --python "$ARENA_TOOLS/eval-openai-evals/bin/python" openai pyyaml numpy pandas tqdm fire backoff blobfile lz4 zstandard pydantic dacite filelock mock termcolor tiktoken aiolimiter beartype networkx
    version "evals (OpenAI's)" "$("$ARENA_TOOLS/eval-openai-evals/bin/python" -c "import importlib.metadata as m; print(m.version('evals'))")";;
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
    version llm-guard "$("$ARENA_TOOLS/guard-llm-guard/bin/python" -c 'import importlib.metadata as m; print(m.version("llm-guard"))')"
    # NeMo Guardrails with what its sensitive-data rail needs: Presidio and spaCy's large English model.
    "$ARENA_TOOLS/uv/bin/uv" venv -q --python 3.13 "$ARENA_TOOLS/guard-nemo"
    "$ARENA_TOOLS/uv/bin/uv" pip install -q --python "$ARENA_TOOLS/guard-nemo/bin/python" 'nemoguardrails[sdd]' langchain-openai presidio-analyzer presidio-anonymizer pip
    "$ARENA_TOOLS/guard-nemo/bin/python" -m spacy download en_core_web_lg > /dev/null 2>&1
    version nemoguardrails "$("$ARENA_TOOLS/guard-nemo/bin/python" -c 'import importlib.metadata as m; print(m.version("nemoguardrails"))')"
    # guardrails-ai with its DetectPII validator, which is a package on PyPI. Its settings file, in a home folder of
    # its own, turns its usage metrics off. Its language model is fetched here so the race doesn't wait for it.
    python3 -m venv "$ARENA_TOOLS/guard-guardrails-ai" && "$ARENA_TOOLS/guard-guardrails-ai/bin/pip" install -q guardrails-ai guardrails-ai-detect-pii
    mkdir -p "$ARENA_TOOLS/guard-guardrails-ai/home" && printf 'enable_metrics=false\nuse_remote_inferencing=false\n' > "$ARENA_TOOLS/guard-guardrails-ai/home/.guardrailsrc"
    "$ARENA_TOOLS/guard-guardrails-ai/bin/python" -m spacy download en_core_web_lg > /dev/null 2>&1
    version guardrails-ai "$("$ARENA_TOOLS/guard-guardrails-ai/bin/python" -c 'import importlib.metadata as m; print(m.version("guardrails-ai"), "with guardrails-ai-detect-pii", m.version("guardrails-ai-detect-pii"))')";;
  compress) py_libs headroom-ai tiktoken;;
  pick)
    # RouteLLM with CPU-only PyTorch, and its repo's per-prompt results for MMLU and GSM8K, which both routers score.
    python3 -m venv "$ARENA_TOOLS/pick-routellm" && "$ARENA_TOOLS/pick-routellm/bin/pip" install -q --extra-index-url https://download.pytorch.org/whl/cpu routellm
    version routellm "$("$ARENA_TOOLS/pick-routellm/bin/python" -c 'import importlib.metadata as m; print(m.version("routellm"))'), its BERT router, checkpoint routellm/bert_gpt4_augmented"
    mkdir -p run/pick
    [ -d run/pick/RouteLLM ] || { git clone -q --depth 1 --filter=blob:none --sparse https://github.com/lm-sys/RouteLLM run/pick/RouteLLM && git -C run/pick/RouteLLM sparse-checkout set routellm/evals; }
    version routellm-data "RouteLLM's repo at $(git -C run/pick/RouteLLM rev-parse --short HEAD)"
    # The other pickers, each in an environment of its own with CPU-only PyTorch, as released.
    uv=$(arena_uv)
    pick_env() { # NAME PYTHON PACKAGE [WHAT-TO-INSTALL..]
      local name=$1 python=$2 package=$3; shift 3
      "$uv" venv -q --python "$python" "$ARENA_TOOLS/pick-$name" && "$uv" pip install -q --python "$ARENA_TOOLS/pick-$name/bin/python" --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match "${@:-$package}" \
        || echo "$package didn't install" >&2
      version "$package" "$("$ARENA_TOOLS/pick-$name/bin/python" -c "import importlib.metadata as m; print(m.version('$package'))" 2>/dev/null)"
    }
    pick_env nadirclaw 3.12 nadirclaw
    pick_env uncommonroute 3.12 uncommon-route
    pick_env rorf 3.11 rorf
    pick_env semantic-router 3.12 semantic-router 'semantic-router[fastembed]'
    # ClawRouter is a Node package. Its install scripts aren't run, since only its router module is used.
    mkdir -p "$ARENA_TOOLS/pick-clawrouter" && npm install --silent --no-audit --no-fund --ignore-scripts --prefix "$ARENA_TOOLS/pick-clawrouter" @blockrun/clawrouter
    version @blockrun/clawrouter "$(node -e "console.log(require('$ARENA_TOOLS/pick-clawrouter/node_modules/@blockrun/clawrouter/package.json').version)")"
    # LLMRouter from its repo, as its README installs it, since its example data and configs live there. Its KNN
    # router is trained by its own command on that example data.
    [ -d "$ARENA_TOOLS/src/llmrouter" ] || { mkdir -p "$ARENA_TOOLS/src" && git clone -q --depth 1 https://github.com/ulab-uiuc/LLMRouter "$ARENA_TOOLS/src/llmrouter"; }
    pick_env llmrouter 3.11 llmrouter-lib -e "$ARENA_TOOLS/src/llmrouter"
    (cd "$ARENA_TOOLS/src/llmrouter" && HOME="$ARENA_TOOLS/pick-llmrouter/home" HF_HOME="$ARENA_TOOLS/models" "$ARENA_TOOLS/pick-llmrouter/bin/llmrouter" train --router knnrouter --config configs/model_config_train/knnrouter.yaml > "$ARENA_TOOLS/pick-llmrouter/train.log" 2>&1) \
      || echo "LLMRouter's KNN router didn't train: $(tail -2 "$ARENA_TOOLS/pick-llmrouter/train.log")" >&2
    # Plano with its router model served locally, as its docs describe for running without its hosted router.
    pick_env plano 3.12 planoai planoai huggingface_hub
    mkdir -p "$ARENA_TOOLS/models/arch-router"
    HF_HOME="$ARENA_TOOLS/models" "$ARENA_TOOLS/pick-plano/bin/python" -c 'import sys; from huggingface_hub import hf_hub_download; hf_hub_download("katanemo/Arch-Router-1.5B.gguf", "Arch-Router-1.5B-Q4_K_M.gguf", local_dir=sys.argv[1])' "$ARENA_TOOLS/models/arch-router" > /dev/null 2>&1 \
      || echo "Plano's router model didn't download" >&2
    "$CONTAINER" pull -q ghcr.io/mostlygeek/llama-swap:cpu > /dev/null
    version "Plano's router model" "katanemo/Arch-Router-1.5B.gguf, Q4_K_M, served by llama.cpp's server from ghcr.io/mostlygeek/llama-swap:cpu"
    # vLLM's semantic-router, its command from PyPI and its recipes at the tag of the same version.
    pick_env vllm-sr 3.12 vllm-sr
    [ -d "$ARENA_TOOLS/src/vllm-sr-v04" ] || { git clone -q --depth 1 --branch v0.4.0 --filter=blob:none --sparse https://github.com/vllm-project/semantic-router "$ARENA_TOOLS/src/vllm-sr-v04" && git -C "$ARENA_TOOLS/src/vllm-sr-v04" sparse-checkout set config; };;
  mcp)
    # The MCP gateways, each installed as its own docs say.
    uv=$(arena_uv)
    "$uv" venv -q --python 3.12 "$ARENA_TOOLS/mcp-contextforge" && "$uv" pip install -q --python "$ARENA_TOOLS/mcp-contextforge/bin/python" mcp-contextforge-gateway || echo "ContextForge didn't install" >&2
    version mcp-contextforge-gateway "$("$ARENA_TOOLS/mcp-contextforge/bin/python" -c 'import importlib.metadata as m; print(m.version("mcp-contextforge-gateway"))')"
    version nave-mcp "prototype P012, $(sha256sum bin/p012 | cut -c1-12)";;
  image)
    portkey_install; bifrost_install
    "$CONTAINER" pull -q ghcr.io/berriai/litellm:main-stable > /dev/null
    version litellm-image "$("$CONTAINER" image inspect ghcr.io/berriai/litellm:main-stable --format 'created {{.Created}}') (image ghcr.io/berriai/litellm:main-stable)"
    "$CONTAINER" build -q -t localhost/nave-arena-gateway:latest -f Containerfile . > /dev/null;;
  *) echo "no group $group" >&2; exit 2;;
esac
bin/race run "races/$group.json" --out "results/$group"
