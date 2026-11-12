#!/usr/bin/env bash
# Microsoft's MCP gateway, for the MCP race. Usage: clients/ms_mcp_gateway.sh install|up|down
# It runs only on Kubernetes and deploys an MCP server itself from an image, so this follows its README's local
# deployment on a kind cluster: a local registry at localhost:5000, its two images built with `dotnet publish`, its
# manifests applied, and the stand-in MCP server pushed as an image and registered as an adapter. It needs Docker
# and the .NET SDK, which a GitHub runner has. The gateway's service is reached through a node port, since a
# port-forward would put kubectl's own proxy in the path.
set -uo pipefail
. ./lib.sh
src="$ARENA_TOOLS/src/ms-mcp-gateway" k="$ARENA_TOOLS/k8s"
export KUBECONFIG="$k/kubeconfig-arena-ms"
say() { echo "ms-mcp: $*" >&2; }
case $1 in
  install)
    mkdir -p "$k" "$ARENA_TOOLS/src"
    [ -d "$src" ] || git clone -q --depth 1 https://github.com/microsoft/mcp-gateway "$src" || exit 1
    docker run -d --restart=always --name arena-registry -p 127.0.0.1:5000:5000 registry:2.8 > /dev/null || exit 1
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\ncontainerdConfigPatches:\n  - |-\n    [plugins."io.containerd.grpc.v1.cri".registry]\n      config_path = "/etc/containerd/certs.d"\nnodes:\n  - role: control-plane\n    extraPortMappings:\n      - {containerPort: 30090, hostPort: 8790, listenAddress: "127.0.0.1", protocol: TCP}\n' > "$k/kind-arena-ms.yaml"
    kind create cluster --name arena-ms --config "$k/kind-arena-ms.yaml" --wait 180s > "$k/kind-ms.log" 2>&1 || { say "the kind cluster didn't come up: $(tail -3 "$k/kind-ms.log")"; exit 1; }
    docker network connect kind arena-registry 2> /dev/null
    docker exec arena-ms-control-plane sh -c 'mkdir -p /etc/containerd/certs.d/localhost:5000 && printf "[host.\"http://arena-registry:5000\"]\n" > /etc/containerd/certs.d/localhost:5000/hosts.toml'
    docker update --cpuset-cpus "$GATEWAY_CPUS" arena-ms-control-plane > /dev/null 2>&1 || say "the cluster's node isn't kept to CPUs $GATEWAY_CPUS"
    # The stand-in MCP server as an image, listening where the gateway expects an adapter's server.
    mkdir -p run/ms-standin && cp bin/mcpstandin run/ms-standin/ && printf 'FROM scratch\nCOPY mcpstandin /mcpstandin\nEXPOSE 8000\nENTRYPOINT ["/mcpstandin", "0.0.0.0:8000", "--name", "standin", "--tools", "8"]\n' > run/ms-standin/Dockerfile
    docker build -q -t localhost:5000/mcp-standin:1.0.0 run/ms-standin > /dev/null && docker push -q localhost:5000/mcp-standin:1.0.0 > /dev/null || { say "the stand-in's image didn't build or push"; exit 1; }
    for project in Service Tools; do
      dotnet publish "$src/dotnet/Microsoft.McpGateway.$project/src/Microsoft.McpGateway.$project.csproj" -c Release /p:PublishProfile=localhost_5000.pubxml > "$k/dotnet-$project.log" 2>&1 \
        || { say "dotnet publish of $project failed: $(grep -m3 -i 'error' "$k/dotnet-$project.log")"; exit 1; }
    done
    kubectl apply -f "$src/deployment/k8s/local-deployment.yml" > /dev/null || exit 1
    kubectl -n adapter rollout status deploy/mcpgateway --timeout=300s > /dev/null || { say "the gateway didn't roll out: $(kubectl -n adapter get pods 2>&1 | tail -5)"; kubectl -n adapter describe pods 2>&1 | grep -i -A3 'warning\|failed' | head -20 >&2; exit 1; }
    kubectl -n adapter patch svc mcpgateway-service --type=json -p '[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/0/nodePort","value":30090}]' > /dev/null || exit 1
    version ms-mcp-gateway "microsoft/mcp-gateway at $(git -C "$src" rev-parse --short HEAD), built with .NET $(dotnet --version), on Kubernetes $(kubectl version -o json 2> /dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])') in kind";;
  up)
    for _ in $(seq 1 240); do
      code=$(curl -s -m 5 -o run/ms-adapters.txt -w '%{http_code}' http://127.0.0.1:8790/adapters); [ "$code" = 200 ] && break; sleep 0.5
    done
    [ "${code:-}" = 200 ] || { say "the gateway's /adapters answered ${code:-nothing}: $(head -c 300 run/ms-adapters.txt 2> /dev/null)"; kubectl -n adapter get pods,svc,networkpolicy 2>&1 | tail -14 >&2; exit 1; }
    grep -q '"standin"' run/ms-adapters.txt || curl -s -m 60 -o run/ms-adapter.txt -w '%{http_code}\n' -H 'content-type: application/json' -d '{"name":"standin","imageName":"mcp-standin","imageVersion":"1.0.0","description":"the stand-in MCP server"}' http://127.0.0.1:8790/adapters > run/ms-adapter.code
    for _ in $(seq 1 240); do
      bin/mcpload http://127.0.0.1:8790/adapters/standin/mcp --what list --bare standin --expect 8 --calls 1 > run/ms-list.txt 2>&1 && exit 0
      sleep 0.5
    done
    say "the adapter never listed the stand-in's tools. Creating it answered $(cat run/ms-adapter.code 2> /dev/null): $(head -c 300 run/ms-adapter.txt 2> /dev/null). The list said: $(head -c 300 run/ms-list.txt)"
    kubectl -n adapter get pods 2>&1 | tail -6 >&2; exit 1;;
  down) exit 0;;
esac
