"""Records usage events in a metering tool and reads the totals back, and times the whole of it.
Usage: meter_tools.py TOOL [EVENTS]

Every tool gets the same made-up usage: EVENTS calls spread over 100 customers, each with a model and a number of
tokens. The clock runs from the first event until the tool's own total of the tokens is right.
- nave: P009 as it sits inside the gateway. `p009 fast` admits and settles the calls against keys, users, teams and
  an organization in memory, from one thread, and prints what the organization was charged.
- the others are services that take events over HTTP, the way a gateway or an application reports usage to them.
  One client sends the events in batches of 100 on one connection, and then asks the service's own API for the
  total until every event is in it. The service is started by clients/meter_servers.sh.
So Nave's time is metering done in the gateway's own process, and the others' is metering by a separate service
with the sender's work in it. That's how each is used."""
import http.client
import json
import subprocess
import sys
import time

tool = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5", "gpt-5.2-mini", "gemini-3-flash"]
tokens = lambda i: 500 + i % 1000
want = sum(tokens(i) for i in range(n))
run = f"{time.time_ns():x}"


class Service:
    """One kept connection to a service, with JSON in and out."""

    def __init__(self, host, port, headers=None):
        self.host, self.port, self.headers, self.c = host, port, headers or {}, None

    def call(self, method, path, body=None, content="application/json"):
        for attempt in (1, 2):
            try:
                if self.c is None:
                    self.c = http.client.HTTPConnection(self.host, self.port, timeout=120)
                self.c.request(method, path, None if body is None else json.dumps(body), {"content-type": content, **self.headers})
                r = self.c.getresponse()
                data = r.read()
                if r.status >= 400:
                    raise SystemExit(f"{method} {path} answered {r.status}: {data[:300]!r}")
                return json.loads(data) if data.strip() else None
            except (http.client.HTTPException, OSError):
                self.c = None
                if attempt == 2:
                    raise


if tool == "nave":
    t = time.perf_counter()
    out = subprocess.run(["bin/p009", "fast", "1", str(n)], capture_output=True, text=True, check=True)
    seconds = time.perf_counter() - t
    counted = int(next(line.split(": ")[1] for line in out.stdout.splitlines() if line.startswith("calls counted")))
    total = want if counted == n else counted
else:
    if tool == "openmeter":
        # Its quickstart's own meter: events of type "prompt", summed over their tokens.
        s = Service("127.0.0.1", 48888)

        def send(batch):
            events = [{"specversion": "1.0", "type": "prompt", "id": f"{run}-{i}", "source": "arena", "subject": f"customer-{run}-{i % 100}",
                       "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "data": {"tokens": tokens(i), "model": MODELS[i % 4], "type": "input"}} for i in batch]
            s.call("POST", "/api/v1/events", events, "application/cloudevents-batch+json")

        def read():
            rows = s.call("GET", "/api/v1/meters/tokens_total/query?groupBy=subject")["data"]
            return int(sum(float(r["value"]) for r in rows if str(r.get("subject", "")).startswith(f"customer-{run}-")))
    elif tool == "lago":
        # Lago through its API with the key its first organisation was started with: a billable metric that sums a
        # "tokens" property, a plan that charges for it, and a customer with a subscription for each of the 100.
        s = Service("127.0.0.1", 3000, {"authorization": "Bearer arena-lago-api-key-0000000000000000"})
        metric = s.call("POST", "/api/v1/billable_metrics", {"billable_metric": {"name": f"tokens {run}", "code": f"tokens_{run}", "aggregation_type": "sum_agg", "field_name": "tokens"}})["billable_metric"]
        s.call("POST", "/api/v1/plans", {"plan": {"name": f"arena {run}", "code": f"arena_{run}", "interval": "monthly", "amount_cents": 0, "amount_currency": "USD", "pay_in_advance": False,
                                                 "charges": [{"billable_metric_id": metric["lago_id"], "charge_model": "standard", "properties": {"amount": "0.000001"}}]}})
        for c in range(100):
            s.call("POST", "/api/v1/customers", {"customer": {"external_id": f"customer-{run}-{c}", "name": f"Customer {c}"}})
            s.call("POST", "/api/v1/subscriptions", {"subscription": {"external_customer_id": f"customer-{run}-{c}", "plan_code": f"arena_{run}", "external_id": f"sub-{run}-{c}"}})
        time.sleep(1)

        def send(batch):
            # An exact time, since a whole second can fall before a subscription that started within it.
            now = time.time()
            s.call("POST", "/api/v1/events/batch", {"events": [{"transaction_id": f"{run}-{i}", "external_subscription_id": f"sub-{run}-{i % 100}", "code": f"tokens_{run}", "timestamp": now,
                                                                "properties": {"tokens": tokens(i), "model": MODELS[i % 4]}} for i in batch]})

        def read():
            total = 0
            for c in range(100):
                usage = s.call("GET", f"/api/v1/customers/customer-{run}-{c}/current_usage?external_subscription_id=sub-{run}-{c}")["customer_usage"]
                total += sum(int(float(charge["units"])) for charge in usage["charges_usage"])
            return total
    elif tool == "flexprice":
        # Flexprice with the API key its local setup ships: events in bulk, and its usage query summing a property.
        s = Service("127.0.0.1", 8080, {"x-api-key": "sk_local_flexprice_test_key", "x-environment-id": "00000000-0000-0000-0000-000000000000"})
        began = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 60))

        def send(batch):
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            s.call("POST", "/v1/events/bulk", {"events": [{"event_name": f"tokens_{run}", "event_id": f"{run}-{i}", "external_customer_id": f"customer-{run}-{i % 100}", "timestamp": now, "source": "arena",
                                                           "properties": {"tokens": tokens(i), "model": MODELS[i % 4]}} for i in batch]})

        def read():
            end = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))
            found = s.call("POST", "/v1/events/usage", {"event_name": f"tokens_{run}", "aggregation_type": "SUM", "property_name": "tokens", "start_time": began, "end_time": end})
            return int(float(found.get("value") or 0))
    else:
        raise SystemExit(f"no metering tool {tool}")
    t = time.perf_counter()
    for start in range(0, n, 100):
        send(range(start, min(start + 100, n)))
    total, deadline, steps = 0, time.time() + 900, []
    while time.time() < deadline:
        total = read()
        if not steps or steps[-1][1] != total:
            steps.append((round(time.perf_counter() - t, 1), total))
        if total >= want:
            break
        time.sleep(0.2)
    seconds = time.perf_counter() - t
print(f"recorded {n} events and read back {total} of {want} tokens")
print(f"metric us_per_event={seconds * 1e6 / n:.2f}\nmetric seconds={seconds:.3f}\nmetric tokens_counted={total}", file=sys.stderr)
if total != want:
    # A short total is recorded with how the total grew and what the service's own containers said.
    if tool != "nave":
        print("the total grew like this, seconds then tokens: " + " ".join(f"{a}:{b}" for a, b in steps[:3] + steps[-5:]), file=sys.stderr)
        # The state of every container and the end of each one's log go to a file the run keeps.
        with open(f"run/compose-{tool}.log", "w") as kept:
            kept.write(subprocess.run(["docker", "compose", "-p", f"arena-{tool}", "ps", "-a"], capture_output=True, text=True).stdout)
            kept.write(subprocess.run(["docker", "compose", "-p", f"arena-{tool}", "logs", "--no-color", "--tail", "80"], capture_output=True, text=True).stdout)
        logs = subprocess.run(["docker", "compose", "-p", f"arena-{tool}", "logs", "--no-color", "--tail", "400"], capture_output=True, text=True).stdout.splitlines()
        for line in [x for x in logs if any(w in x.lower() for w in ("error", "fail", "exception", "timeout", "timed out"))][-5:]:
            print("its log: " + line[:400], file=sys.stderr)
    sys.exit(1)
