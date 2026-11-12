# Antirion, from its own official image, started from a config document in its own schema, the way its benchmark
# harness starts it: the stand-in as a provider of OpenAI's type and of Anthropic's, one deployment and model
# "mock", one project and one key, its embedded store. Request logs are off and metrics on, as in its benchmark's
# minimal profile. It checks the caller's key and prices every call. The key is in its own format, with the
# checksum its format ends in. Its throttle on failed sign-ins is raised out of the way, as its own benchmark's
# profile does, since one edge check sends a wrong key and the throttle then refuses the checks after it. The container runs as the caller's user, so its store can write to the mounted folder.
antirion_kind=container
antirion_image=docker.io/eliasbiondo/antirion:latest
antirion_title() { echo Antirion; }
antirion_install() {
  "$CONTAINER" pull -q "$antirion_image" > /dev/null
  version antirion "$("$CONTAINER" run --rm "$antirion_image" version 2>/dev/null | head -1) (image $antirion_image)"
}
antirion_url() { echo http://127.0.0.1:8480; }
antirion_start() { # MODE
  local target='{"deployment":"mock"}' policies='{}' failing=''
  rm -rf run/antirion; mkdir -p run/antirion/store
  if [ "${1:-}" = fallback ]; then
    failing='"failing":{"type":"openai","base_url":"http://127.0.0.1:9001/v1","auth":{"method":"api_key","api_key":"sk-standin"}},'
    target='{"type":"fallback","children":[{"deployment":"failing"},{"deployment":"mock"}]}'
  fi
  [ "${1:-}" = cache ] && policies='{"cache":{"enabled":true}}'
  cat > run/antirion/antirion.json <<JSON
{"version":1,"server":{"listen":"127.0.0.1:8480"},"admin":{"listen":"127.0.0.1:8481"},
 "auth":{"admin":{"bootstrap_token":"ak-antirion-arena-admin-token-0000000000"},"failed_auth_throttle":{"max_failures":1000000000,"window":"1s"}},
 "store":{"backend":"embedded","embedded":{"path":"/data/store"}},
 "providers":{$failing"standin":{"type":"openai","base_url":"http://127.0.0.1:9000/v1","auth":{"method":"api_key","api_key":"sk-standin"}}},
 "deployments":{"mock":{"provider":"standin","model":"mock","price":{"input":"1.00","output":"2.00"}}${failing:+,\"failing\":{\"provider\":\"failing\",\"model\":\"mock\",\"price\":{\"input\":\"1.00\",\"output\":\"2.00\"\}\}}},
 "models":{"mock":{"target":$target}},
 "organizations":{"arena":{}},"teams":{"arena":{"organization":"arena"}},"projects":{"arena":{"team":"arena"}},
 "keys":{"arena":{"project":"arena","secret":"\${env:ARENA_KEY}"}},
 "policies":$policies,
 "observability":{"request_logs":{"enabled":false},"metrics":{"enabled":true}}}
JSON
  container_up antirion 8480 --user "$(id -u):$(id -g)" -e ARENA_KEY="$(antirion_key)" -v "$(mount_of run/antirion /data)" "$antirion_image" serve --config /data/antirion.json
}
antirion_key() { echo sk-antirion-arenaarena00-ArenaRace0ArenaRace0ArenaRace0ArenaRace0Are0MmBkz; }
antirion_features() { echo "routes by model through deployments, falls back, takes OpenAI's and Anthropic's formats, checks the caller's key, prices every call, keeps metrics. Request log off, as in its own benchmark's minimal profile"; }
# Its README's benchmark table has simple chat at 10,000 calls a second on four vCPUs, sent open loop and timed
# from each call's due time (docs/benchmarks.md in its repo).
antirion_own_benchmark() { echo "10000 100000 256||Antirion's simple chat at 10,000 calls a second"; }
