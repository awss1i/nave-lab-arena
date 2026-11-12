# Nave's gateway prototype, a static binary in bin/, with a loop on each CPU it's given.
nave_install() { version nave "prototype P006, $(sha256sum bin/p006-formats | cut -c1-12)"; }
nave_start() { UP_PORT=4000 ./up.sh nave "$GATEWAY_CPUS" bin/p006-formats --listen 127.0.0.1:4000 --cpus "$GATEWAY_CPUS" --route mock=openai:http://127.0.0.1:9000/v1 ${1:+--cache}; }
nave_stop() { ./down.sh nave; }
nave_mb() { now_mb nave; }
