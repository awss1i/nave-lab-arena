# kgateway, which runs only on Kubernetes, in a kind cluster of one node made for it. Its Helm charts install it
# as its docs say, and a Gateway, a Backend and an HTTPRoute send every call to the stand-in. From version 2.3 its
# LLM features live in agentgateway, which is raced on its own, so here it's an Envoy proxy passing calls on.
# The whole node, Kubernetes' own control plane included, is kept to the gateway's CPUs. Memory and CPU time are
# counted for kgateway's own pods only: its controller and the Envoy proxy it starts for the Gateway.
# The stand-in listens on every address, since the proxy reaches it from inside the cluster.
kgateway_kind=cluster
kgateway_title() { echo kgateway; }
kgateway_standin_host() { echo 0.0.0.0; }
kgateway_env() {
  export KUBECONFIG="$ARENA_TOOLS/k8s/kubeconfig-arena" HELM_CACHE_HOME="$ARENA_TOOLS/k8s/helm-cache" HELM_CONFIG_HOME="$ARENA_TOOLS/k8s/helm-config" HELM_DATA_HOME="$ARENA_TOOLS/k8s/helm-data"
  [ "$(basename "$CONTAINER")" = podman ] && export KIND_EXPERIMENTAL_PROVIDER=podman
  PATH="$ARENA_TOOLS/k8s:$PATH"
}
# Runs a command inside the cluster's one node.
kgateway_node() { "$CONTAINER" exec arena-control-plane "$@"; }
kgateway_install() {
  local d="$ARENA_TOOLS/k8s" v host
  mkdir -p "$d"; kgateway_env
  if ! command -v kind > /dev/null; then
    v=$(latest_tag kubernetes-sigs/kind)
    curl -fsSL -o "$d/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$v/kind-linux-amd64" && chmod +x "$d/kind"
  fi
  command -v kubectl > /dev/null || { curl -fsSL -o "$d/kubectl" "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x "$d/kubectl"; }
  command -v helm > /dev/null || { v=$(latest_tag helm/helm); curl -fsSL "https://get.helm.sh/helm-$v-linux-amd64.tar.gz" | tar -xz -C "$d" --strip-components=1 linux-amd64/helm; }
  if ! kind get clusters 2> /dev/null | grep -qx arena; then
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n  - role: control-plane\n    extraPortMappings:\n      - {containerPort: 30080, hostPort: 8780, listenAddress: "127.0.0.1", protocol: TCP}\n' > "$d/kind-arena.yaml"
    if [ "$(basename "$CONTAINER")" = podman ]; then systemd-run --scope --user -q -p Delegate=yes kind create cluster --name arena --config "$d/kind-arena.yaml" --wait 180s > "$d/kind.log" 2>&1
    else kind create cluster --name arena --config "$d/kind-arena.yaml" --wait 180s > "$d/kind.log" 2>&1; fi || { echo "the kind cluster didn't come up: $(tail -3 "$d/kind.log")" >&2; return 1; }
  fi
  # Not every rootless podman can change a running container's CPUs, and a local run is only a smoke.
  "$CONTAINER" update --cpuset-cpus "$GATEWAY_CPUS" arena-control-plane > /dev/null 2>&1 || echo "the cluster's node isn't kept to CPUs $GATEWAY_CPUS" >&2
  v=$(latest_tag kubernetes-sigs/gateway-api)
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$v/standard-install.yaml" > /dev/null || return 1
  helm upgrade -i --create-namespace -n kgateway-system kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds > /dev/null 2>&1 || return 1
  helm upgrade -i -n kgateway-system kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway > /dev/null 2>&1 || return 1
  kubectl -n kgateway-system rollout status deploy/kgateway --timeout=300s > /dev/null || return 1
  # The host's address as the cluster sees it.
  if [ "$(basename "$CONTAINER")" = podman ]; then host=$(kgateway_node getent hosts host.containers.internal | awk '{ print $1; exit }')
  else host=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -m1 '^[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*$'); fi
  [ -n "$host" ] || { echo "the host's address inside the cluster wasn't found" >&2; return 1; }
  cat > "$d/kgateway-arena.yaml" <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: arena, namespace: default}
spec:
  gatewayClassName: kgateway
  listeners:
    - {name: http, port: 8080, protocol: HTTP, allowedRoutes: {namespaces: {from: Same}}}
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata: {name: standin, namespace: default}
spec:
  type: Static
  static:
    hosts:
      - {host: "$host", port: 9000}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: standin, namespace: default}
spec:
  parentRefs: [{name: arena}]
  rules:
    - backendRefs: [{name: standin, group: gateway.kgateway.dev, kind: Backend}]
YAML
  version kgateway "$(helm list -n kgateway-system -o json | python3 -c 'import json, sys; print(next(r["app_version"] for r in json.load(sys.stdin) if r["name"] == "kgateway"))'), Gateway API $v, Kubernetes $(kubectl version -o json 2> /dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])') in kind"
}
kgateway_url() { echo http://127.0.0.1:8780; }
# Starting it is creating the Gateway: kgateway's controller starts an Envoy proxy for it, and the node port that
# the host reaches is set on the proxy's service.
kgateway_start() { # MODE
  kgateway_env
  kubectl apply -f "$ARENA_TOOLS/k8s/kgateway-arena.yaml" > /dev/null || return 1
  for _ in $(seq 1 600); do kubectl -n default get svc arena > /dev/null 2>&1 && break; sleep 0.1; done
  kubectl -n default patch svc arena --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]' > /dev/null || return 1
  for _ in $(seq 1 1200); do
    curl -fsS -m 2 -o /dev/null -H 'content-type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"ready"}]}' http://127.0.0.1:8780/v1/chat/completions 2>/dev/null && return 0
    sleep 0.05
  done
  echo "kgateway never answered a call" >&2; return 1
}
kgateway_stop() {
  kgateway_env
  kubectl delete -f "$ARENA_TOOLS/k8s/kgateway-arena.yaml" --ignore-not-found --wait=true > /dev/null 2>&1
  for _ in $(seq 1 300); do [ -z "$(kubectl -n default get pods -o name 2> /dev/null)" ] && break; sleep 0.1; done
}
# What kgateway's own containers hold and have used: its controller and the Gateway's proxy, read from the node's
# container runtime.
kgateway_stats() { # FIELD
  kgateway_node crictl stats -o json 2> /dev/null | python3 -c '
import json, sys
total = 0
for s in json.load(sys.stdin).get("stats", []):
    ns = s["attributes"]["labels"].get("io.kubernetes.pod.namespace")
    if ns == "kgateway-system" or (ns == "default" and s["attributes"]["labels"].get("io.kubernetes.pod.name", "").startswith("arena-")):
        total += int(s["memory"]["workingSetBytes"]["value"]) if sys.argv[1] == "mb" else int(s["cpu"]["usageCoreNanoSeconds"]["value"])
print(f"{total / 1048576:.1f}" if sys.argv[1] == "mb" else total // 1000)' "$1"
}
kgateway_mb() { kgateway_stats mb; }
kgateway_cpu_us() { kgateway_stats cpu; }
# Its two images, the controller and the Envoy wrapper, as the node holds them.
kgateway_size_mb() {
  kgateway_node crictl images -o json 2> /dev/null | python3 -c '
import json, sys
images = [i for i in json.load(sys.stdin)["images"] if any("kgateway" in t for t in i.get("repoTags", []))]
print(f"{sum(int(i["size"]) for i in images) / 1e6:.1f}")'
}
kgateway_clean() { kgateway_stop; }
kgateway_skip() { echo "fallback cache"; }
kgateway_features() { echo "an Envoy proxy programmed through Kubernetes' Gateway API, passing every call on to one upstream by route. No key check and no LLM features in this version, which moved to agentgateway. It runs in a kind cluster of one node, and only its own pods are measured"; }
