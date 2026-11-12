# Portkey's open-source gateway, from its own official image, which carries the library versions Portkey released
# with. It takes its route from headers on each call: the provider, and the stand-in's address as a custom host.
# (A fresh `npm install` of the same release pulls a newer HTTP library with which its streamed replies fail.)
portkey_kind=container
portkey_install() {
  "$CONTAINER" pull -q docker.io/portkeyai/gateway:latest > /dev/null
  version portkey-gateway "$("$CONTAINER" run --rm --entrypoint node docker.io/portkeyai/gateway:latest -e "console.log(require('./package.json').version)") (image docker.io/portkeyai/gateway:latest)"
}
portkey_start() { container_up portkey 8787 docker.io/portkeyai/gateway:latest; }
portkey_url() { echo http://127.0.0.1:8787; }
# Its fallback is a config sent with each call: the targets in order.
portkey_load_args() {
  if [ "$(cat run/portkey.mode 2>/dev/null)" = fallback ]; then
    printf '%s\n' --header 'x-portkey-config: {"strategy":{"mode":"fallback"},"targets":[{"provider":"openai","custom_host":"http://127.0.0.1:9001/v1","api_key":"sk-standin"},{"provider":"openai","custom_host":"http://127.0.0.1:9000/v1","api_key":"sk-standin"}]}'
  else
    printf '%s\n' --header "x-portkey-provider: openai" --header "x-portkey-custom-host: http://127.0.0.1:9000/v1"
  fi
}
# Its open-source cache answers `x-portkey-cache-status: DISABLED` to a cache setting.
# Its `/v1/messages` answers "messages is not supported by openai" when the provider is of OpenAI's kind.
portkey_skip() { echo "cache messages"; }
portkey_features() { echo "routes by headers on each call, falls back, takes OpenAI's format. No key check, no request log, no spend"; }
portkey_title() { echo "Portkey"; }
portkey_image=docker.io/portkeyai/gateway:latest
