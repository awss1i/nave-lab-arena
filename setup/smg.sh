# SMG, from its own official image, with the stand-in as its one worker, of the OpenAI kind, picked by round robin.
smg_kind=container
smg_image=docker.io/lightseekorg/smg:latest
smg_title() { echo SMG; }
smg_install() {
  "$CONTAINER" pull -q "$smg_image" > /dev/null
  version smg "$("$CONTAINER" run --rm --entrypoint python3 "$smg_image" -c 'import importlib.metadata as m; print(m.version("smg"))' 2>/dev/null) (image $smg_image)"
}
smg_start() { # MODE
  container_up smg 30000 "$smg_image" --host 127.0.0.1 --port 30000 --worker-urls http://127.0.0.1:9000 --backend openai --policy round_robin --log-level error --runtime-worker-threads "$(echo "$GATEWAY_CPUS" | tr ',' '\n' | wc -l)" || return 1
  # It answers on its port before it has registered its worker.
  for _ in $(seq 1 100); do
    curl -fsS -m 2 -o /dev/null -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:30000/v1/chat/completions 2>/dev/null && return 0
    sleep 0.1
  done
  return 0
}
smg_url() { echo http://127.0.0.1:30000; }
# Its `/v1/messages` answers "Messages API not yet implemented for this router".
smg_skip() { echo "messages fallback cache"; }
smg_features() { echo "balances load across inference workers, takes OpenAI's format. No key check"; }
