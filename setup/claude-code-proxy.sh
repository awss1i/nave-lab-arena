# claude-code-proxy (1rgs), from its own official image at its one published tag, `main`. It takes Anthropic's format and sends OpenAI's upstream,
# mapping a model with "haiku" in its name to SMALL_MODEL, which is set to the stand-in's "mock". Its whole job
# runs in Anthropic's format.
claude_code_proxy_kind=container
claude_code_proxy_image=ghcr.io/1rgs/claude-code-proxy:main
claude_code_proxy_title() { echo "claude-code-proxy (1rgs)"; }
claude_code_proxy_install() {
  "$CONTAINER" pull -q "$claude_code_proxy_image" > /dev/null
  version claude-code-proxy "$(image_version "$claude_code_proxy_image")"
}
claude_code_proxy_start() { # MODE
  # The image's own command runs it with --reload, which is for development, so it's started without.
  PODMAN_USER= container_up claude-code-proxy 8082 -e OPENAI_API_KEY=sk-standin -e OPENAI_API_BASE=http://127.0.0.1:9000/v1 -e OPENAI_BASE_URL=http://127.0.0.1:9000/v1 \
    -e PREFERRED_PROVIDER=openai -e BIG_MODEL=mock -e SMALL_MODEL=mock "$claude_code_proxy_image" uv run uvicorn server:app --host 127.0.0.1 --port 8082 --log-level error
}
claude_code_proxy_url() { echo http://127.0.0.1:8082; }
claude_code_proxy_format() { echo messages; }
claude_code_proxy_load_args() { printf '%s\n' --model claude-3-5-haiku-20241022; }
claude_code_proxy_skip() { echo "fallback cache"; }
claude_code_proxy_features() { echo "takes Anthropic's format and sends OpenAI's upstream. No key check"; }
