"""What recording a call adds for the caller, for a tool that records from inside the caller's own process.
Usage: log_sdk.py nave|openllmetry [CALLS]
- openllmetry: OpenAI's SDK makes CALLS calls to the stand-in model on port 9000, first as it is and then with
  OpenLLMetry's SDK switched on (Traceloop.init), which wraps every call in a span and hands it to a batching
  exporter. The spans go to a sink on this machine that counts them and throws them away, and the count has to be
  CALLS. The answer is the time the second pass took over the first, a call. Its telemetry is off.
- nave: P013 recording CALLS made-up calls with their bodies into its log file from one thread, a call. That's the
  work the gateway does to record a call, and the caller's own process does none."""
import http.server
import os
import subprocess
import sys
import time

tool = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
if tool == "sink":
    spans = 0

    class Sink(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            global spans
            # Each span of a chat call carries the name "openai.chat" once, so counting the name counts the spans.
            spans += self.rfile.read(int(self.headers.get("content-length", 0))).count(b"\x0bopenai.chat")
            with open("run/log-sdk-sink.count", "w") as f:
                f.write(str(spans))
            self.send_response(200)
            self.send_header("content-length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", 4319), Sink).serve_forever()
elif tool == "nave":
    path = "run/log-nave-record.bin"
    if os.path.exists(path):
        os.remove(path)
    big = n * 10  # More calls than the others make, since one takes microseconds and a short run is all start-up.
    t = time.perf_counter()
    subprocess.run(["bin/p013", "record", "fast", "1", str(big), "1024", path], capture_output=True, text=True, check=True)
    added = (time.perf_counter() - t) * 1e6 / big
    print(f"recorded {big} calls")
elif tool == "openllmetry":
    os.environ.update({"TRACELOOP_TELEMETRY": "false", "TRACELOOP_TRACE_CONTENT": "true", "OTEL_SDK_DISABLED": "false"})

    # The sink is a process of its own, so its work isn't counted as the SDK's.
    if os.path.exists("run/log-sdk-sink.count"):
        os.remove("run/log-sdk-sink.count")
    sink = subprocess.Popen([sys.executable, os.path.abspath(__file__), "sink"])
    time.sleep(0.5)
    from openai import OpenAI

    client = OpenAI(base_url="http://127.0.0.1:9000/v1", api_key="sk-standin", max_retries=0)

    def calls():
        t = time.perf_counter()
        for i in range(n):
            out = client.chat.completions.create(model="mock", messages=[{"role": "user", "content": f"call {i}"}]).choices[0].message.content
            assert out == f"echo: call {i}", out
        return time.perf_counter() - t

    calls()  # A first pass to warm the connection.
    plain = calls()
    keep = os.dup(1)
    os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
    from traceloop.sdk import Traceloop

    Traceloop.init(app_name="arena", api_endpoint="http://127.0.0.1:4319", disable_batch=False)
    sys.stdout.flush()
    os.dup2(keep, 1)
    recorded = calls()
    added = (recorded - plain) * 1e6 / n
    # Outside the clock, the SDK hands over what it still holds, and the sink says how many spans it was sent.
    from opentelemetry import trace

    trace.get_tracer_provider().force_flush(60000)
    sink.terminate()
    with open("run/log-sdk-sink.count") as f:
        took = int(f.read() or 0)
    print(f"made {n} calls twice, and with recording on the sink was sent {took} spans")
    print(f"metric us_per_call_as_it_is={plain * 1e6 / n:.2f}\nmetric us_per_call_recorded={recorded * 1e6 / n:.2f}", file=sys.stderr)
    if took != n:
        sys.exit(1)
else:
    raise SystemExit(f"no tool {tool}")
print(f"metric us_per_call={added:.2f}", file=sys.stderr)
