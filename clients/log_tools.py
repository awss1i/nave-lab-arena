"""Records calls in a log tool and reads them back, and times the whole of it.
Usage: log_tools.py TOOL [CALLS]

Every tool gets the same made-up calls: a model, a key, token counts, a duration, and a prompt and an answer of
about 500 bytes each. The clock runs from the first call handed over until the tool can say how many calls it holds
and the number is right.
- nave: P013 as it sits inside the gateway. `p013 record fast` writes the calls to its log file from one thread, and
  `p013 query` reads the file back and adds up what each key spent.
- the others are servers that take traces over OTLP, the way an application or a gateway sends them. One span a call
  goes through OpenTelemetry's own SDK and its batching exporter to the server's OTLP address, and the server's own
  API is asked for the count until every call is there. The server is started by clients/log_servers.sh.
So Nave's time is a log written in the gateway's own process, and the others' is a log kept by a separate service,
with the sender's work in it. That's how each is used."""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

tool = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5", "gpt-5.2-mini", "gemini-3-flash"]


def get(url, headers=None):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=120) as r:
        return json.loads(r.read())


def post(url, body, headers=None):
    request = urllib.request.Request(url, json.dumps(body).encode(), {"content-type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, timeout=120) as r:
        return json.loads(r.read())


if tool == "nave":
    path = "run/log-nave.bin"
    if os.path.exists(path):
        os.remove(path)
    t = time.perf_counter()
    recorded = subprocess.run(["bin/p013", "record", "fast", "1", str(n), "1024", path], capture_output=True, text=True, check=True).stdout
    asked = subprocess.run(["bin/p013", "query", "fast", path, "0", "18446744073709551615", "1"], capture_output=True, text=True, check=True).stdout
    seconds = time.perf_counter() - t
    held = sum(int(line.split(" calls ")[1].split()[0]) for line in asked.splitlines() if " calls " in line and line.startswith("sk-"))
    size = os.path.getsize(path)
else:
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    headers = {}
    if tool == "phoenix":
        endpoint = "http://127.0.0.1:6006/v1/traces"

        def count():
            found = post("http://127.0.0.1:6006/graphql", {"query": '{ projects { edges { node { name traceCount } } } }'})
            return sum(e["node"]["traceCount"] for e in found["data"]["projects"]["edges"] if e["node"]["name"] == "arena")
    elif tool == "mlflow":
        experiment = post("http://127.0.0.1:5001/api/2.0/mlflow/experiments/create", {"name": f"arena-{time.time_ns()}"})["experiment_id"]
        endpoint, headers = "http://127.0.0.1:5001/v1/traces", {"x-mlflow-experiment-id": experiment}

        def count():
            total, token = 0, None
            while True:
                body = {"locations": [{"type": "MLFLOW_EXPERIMENT", "mlflow_experiment": {"experiment_id": experiment}}], "max_results": 500}
                if token:
                    body["page_token"] = token
                page = post("http://127.0.0.1:5001/api/3.0/mlflow/traces/search", body)
                total += len(page.get("traces", []))
                token = page.get("next_page_token")
                if not token:
                    return total
    elif tool == "langfuse":
        import base64

        basic = {"Authorization": "Basic " + base64.b64encode(b"pk-lf-arena:sk-lf-arena").decode()}
        endpoint, headers = "http://127.0.0.1:3000/api/public/otel/v1/traces", basic

        import urllib.parse

        asked = urllib.parse.quote(json.dumps({"view": "observations", "metrics": [{"measure": "count", "aggregation": "count"}], "dimensions": [], "filters": [],
                                               "fromTimestamp": "2026-01-01T00:00:00Z", "toTimestamp": "2036-01-01T00:00:00Z"}))

        def count():
            found = get(f"http://127.0.0.1:3000/api/public/v2/metrics?query={asked}", basic)["data"]
            return int(found[0]["count_count"]) if found else 0
    elif tool == "opik":
        endpoint, headers = "http://127.0.0.1:5173/api/v1/private/otel/v1/traces", {"projectName": "arena"}

        def count():
            try:
                return int(get("http://127.0.0.1:5173/api/v1/private/traces?project_name=arena&size=1")["total"])
            except urllib.error.HTTPError as e:
                # The project appears with its first trace, and its front door answers 5xx while a count is slow.
                if e.code == 404 or e.code >= 500:
                    return 0
                raise
    elif tool == "langwatch":
        # LangWatch with the API key log_servers.sh made for its project: spans over OTLP, counted by its trace search.
        key = open("run/log-langwatch.key").read().strip()
        endpoint, headers = "http://127.0.0.1:5560/api/otel/v1/traces", {"Authorization": f"Bearer {key}"}

        def count():
            now = int(time.time() * 1000)
            ask = urllib.request.Request("http://127.0.0.1:5560/api/trace/search", json.dumps({"startDate": now - 86400000, "endDate": now + 86400000, "pageSize": 1}).encode(),
                                         {"content-type": "application/json", "X-Auth-Token": key})
            with urllib.request.urlopen(ask, timeout=60) as r:
                return int(json.load(r)["pagination"]["totalHits"])
    elif tool == "latitude":
        # Latitude with the API key and the project log_servers.sh made: spans over OTLP to its ingest service,
        # counted by its API's trace analytics.
        key = open("run/log-latitude.key").read().strip()
        endpoint, headers = "http://127.0.0.1:3002/v1/traces", {"Authorization": f"Bearer {key}", "X-Latitude-Project": "arena"}

        def count():
            return int(get("http://127.0.0.1:3001/v1/projects/arena/traces/analytics", {"Authorization": f"Bearer {key}"})["traces"]["total"])
    else:
        raise SystemExit(f"no log tool {tool}")

    # What the exporter itself complains about is kept, so a short count can be told from a failed send.
    import logging

    complaints = []

    class Keep(logging.Handler):
        def emit(self, record):
            complaints.append(record.getMessage()[:300])

    logging.getLogger("opentelemetry").addHandler(Keep(logging.WARNING))
    provider = TracerProvider(resource=Resource.create({"service.name": "arena", "openinference.project.name": "arena"}))
    processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, headers=headers), max_queue_size=max(n + 1, 2048), max_export_batch_size=512, schedule_delay_millis=200)
    provider.add_span_processor(processor)
    tracer = provider.get_tracer("arena")
    filler = "the quick brown fox jumps over the lazy dog. " * 11
    # What the tool already holds isn't counted as this run's.
    before = count()
    t = time.perf_counter()
    for i in range(n):
        with tracer.start_span("chat " + MODELS[i % 4]) as span:
            span.set_attribute("gen_ai.operation.name", "chat")
            span.set_attribute("gen_ai.request.model", MODELS[i % 4])
            span.set_attribute("gen_ai.usage.input_tokens", 800 + i % 400)
            span.set_attribute("gen_ai.usage.output_tokens", 100 + i % 300)
            span.set_attribute("llm.model_name", MODELS[i % 4])
            span.set_attribute("openinference.span.kind", "LLM")
            span.set_attribute("user.id", f"sk-nave-{i % 48:04x}")
            span.set_attribute("input.value", f"call {i} " + filler)
            span.set_attribute("output.value", f"echo: call {i} " + filler)
    processor.force_flush(600000)
    held, deadline = 0, time.time() + 900
    while time.time() < deadline:
        held = count() - before
        if held >= n:
            break
        time.sleep(0.2)
    seconds = time.perf_counter() - t
    size = 0
print(f"recorded {n} calls and read back {held}")
print(f"metric us_per_call={seconds * 1e6 / n:.1f}\nmetric calls_held={held}\nmetric seconds={seconds:.3f}" + (f"\nmetric bytes_per_call={size / n:.1f}" if size else ""), file=sys.stderr)
if held != n:
    # A short count is recorded with what the exporter and the tool's own containers said about it.
    if tool != "nave":
        if complaints:
            print(f"the exporter complained {len(complaints)} times, last: {complaints[-1]}", file=sys.stderr)
        # The state of every container and the end of each one's log go to a file the run keeps.
        with open(f"run/compose-{tool}.log", "w") as kept:
            kept.write(subprocess.run(["docker", "compose", "-p", f"arena-{tool}", "ps", "-a"], capture_output=True, text=True).stdout)
            kept.write(subprocess.run(["docker", "compose", "-p", f"arena-{tool}", "logs", "--no-color", "--tail", "80"], capture_output=True, text=True).stdout)
        logs = subprocess.run(["docker", "compose", "-p", f"arena-{tool}", "logs", "--no-color", "--tail", "300"], capture_output=True, text=True).stdout.splitlines()
        for line in [x for x in logs if any(w in x.lower() for w in ("error", "fail", "exception", "timeout"))][-4:]:
            print("its log: " + line[:300], file=sys.stderr)
    sys.exit(1)
