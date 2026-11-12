# Portkey's open-source gateway, from its own official image, which carries the library versions Portkey released
# with. It takes its route from headers on each call: the provider, and the stand-in's address as a custom host.
# (A fresh `npm install` of the same release pulls a newer HTTP library with which its streamed replies fail.)
portkey_install() {
  "$CONTAINER" pull -q docker.io/portkeyai/gateway:latest > /dev/null
  version portkey-gateway "$("$CONTAINER" run --rm --entrypoint node docker.io/portkeyai/gateway:latest -e "console.log(require('./package.json').version)") (image docker.io/portkeyai/gateway:latest)"
}
portkey_start() { container_up portkey 8787 docker.io/portkeyai/gateway:latest; }
portkey_stop() { container_down portkey; }
portkey_mb() { container_mb portkey; }
