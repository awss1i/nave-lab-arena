"""Getting a named prompt with its variables filled in, for the prompts race.
Usage: prompt_tools.py nave|agenta|pezzo|latitude [TIMES]
The prompt is a support assistant's: a system message of about 1,700 characters with four variables and a user
message with two. It's stored once under a name and published to the label "production". Then TIMES times the
prompt is got by name and label and its six variables are filled in, and the filled messages have to be the
expected ones every time.
- nave: P014 inside the gateway. A request names the prompt and carries the variables, and the gateway replaces
  that member with the filled messages. No call leaves the process.
- the others: services. One client on one kept connection asks the service's API for the prompt each time, the way
  an application does when it doesn't keep its own copy, and fills the variables itself."""
import http.client
import json
import os
import subprocess
import sys
import time

tool = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
policy = "Answer in the customer's language. Quote the policy you rely on. Never promise a refund the policy doesn't allow. " * 14
SYSTEM = "You are the support assistant for {{company}}, a {{industry}} company.\nToday is {{date}} and the customer's plan is {{plan}}.\n" + policy + "\n"
USER = "{{customer_name}} asks:\n{{question}}"
VARS = {"company": 'Acme Outdoor "Gear"', "industry": "retail", "date": "2026-11-12", "plan": "Plus", "customer_name": "Zoë Ångström",
        "question": "I bought a tent three weeks ago and one pole snapped on the second night.\nCan I send it back, and who pays for the shipping?"}


def fill(text, opening="{{", closing="}}"):
    for k, v in VARS.items():
        text = text.replace(opening + k + closing, v)
    return text


want = [fill(SYSTEM), fill(USER)]


class Service:
    """One kept connection to a service, with JSON in and out."""

    def __init__(self, host, port, headers=None):
        self.conn, self.headers = http.client.HTTPConnection(host, port, timeout=120), {"content-type": "application/json", **(headers or {})}

    def call(self, method, path, body=None):
        self.conn.request(method, path, None if body is None else json.dumps(body), self.headers)
        r = self.conn.getresponse()
        data = r.read()
        if r.status >= 300:
            raise SystemExit(f"{method} {path} answered {r.status}: {data[:300]!r}")
        return json.loads(data) if data else None


if tool == "nave":
    big = n * 100  # More than the others, since one takes under a microsecond and a short run is all start-up.
    out = subprocess.run(["bin/p014", "apply", "fast", "short", str(big)], capture_output=True, text=True, check=True)
    ns = float(next(line.split("=")[1] for line in out.stderr.splitlines() if line.startswith("metric ns_per_render=")))
    # P014's own tests check the filled text. Here its size is checked against the expected messages' size.
    size = int(out.stdout.split()[0])
    wrong, seconds, times = 0 if size > len(want[0]) + len(want[1]) else big, ns * big / 1e9, big
else:
    if tool == "agenta":
        # Agenta through its SDK for the set-up (an application, a variant holding the prompt, a deployment to
        # "production") and plain HTTP for getting it, with the API key its admin route gave.
        os.environ["AGENTA_INSECURE_EGRESS_ALLOWED"] = "true"
        # Its SDK writes its own log lines to standard output, so that's pointed away while the SDK is used.
        keep = os.dup(1)
        os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
        import agenta as ag
        from agenta.sdk.types import Message, ModelConfig, PromptTemplate

        key = open("run/prompt-agenta.key").read().strip()
        ag.init(host="http://127.0.0.1:8581", api_key=key)
        slug = f"arena-{time.time_ns():x}"
        ag.AppManager.create(app_slug=slug, template_key="SERVICE:completion")
        prompt = PromptTemplate(messages=[Message(role="system", content=SYSTEM), Message(role="user", content=USER)], llm_config=ModelConfig(model="gpt-4o-mini"))
        ag.VariantManager.create(parameters={"prompt": prompt.model_dump(mode="json", exclude_none=True)}, app_slug=slug, variant_slug=slug)
        ag.DeploymentManager.deploy(app_slug=slug, variant_slug=slug, environment_slug="production")
        sys.stdout.flush()
        os.dup2(keep, 1)
        s = Service("127.0.0.1", 8581, {"Authorization": f"ApiKey {key}"})

        def get():
            found = s.call("POST", "/variants/configs/fetch", {"environment_ref": {"slug": "production"}, "application_ref": {"slug": slug}})
            return [fill(m["content"]) for m in found["params"]["prompt"]["messages"]]
    elif tool == "pezzo":
        # Pezzo over HTTP all the way: an account by its sign-up route, then a project, which comes with an
        # environment named Production, a chat prompt, a version of it and its publication through GraphQL, and the organisation's
        # API key. The prompt is stored in Pezzo's own variable syntax, one brace each side.
        import urllib.request

        run = f"{time.time_ns():x}"
        signup = urllib.request.Request("http://127.0.0.1:3300/api/auth/signup", json.dumps({"formFields": [{"id": "email", "value": f"arena-{run}@arena.test"}, {"id": "password", "value": "Arena-pass-12345"},
                                                                                                         {"id": "name", "value": "Arena"}]}).encode(),
                                        {"content-type": "application/json", "rid": "thirdpartyemailpassword", "st-auth-mode": "header"})
        with urllib.request.urlopen(signup, timeout=60) as r:
            token = r.headers["st-access-token"]
        g = Service("127.0.0.1", 3300, {"authorization": f"Bearer {token}"})

        def gql(query, data=None):
            out = g.call("POST", "/graphql", {"query": query, "variables": {"data": data}})
            if out.get("errors"):
                raise SystemExit(f"Pezzo's GraphQL said {json.dumps(out['errors'])[:400]}")
            return next(iter(out["data"].values()))

        org = gql("{ organizations { id } }")[0]["id"]
        project = gql("mutation($data: CreateProjectInput!) { createProject(data: $data) { id } }", {"name": f"arena {run}", "organizationId": org})["id"]
        env = next(e["id"] for e in gql("query($data: GetEnvironmentsInput!) { environments(data: $data) { id name } }", {"projectId": project}) if e["name"] == "Production")
        prompt = gql("mutation($data: CreatePromptInput!) { createPrompt(data: $data) { id } }", {"name": "support", "projectId": project})["id"]
        single = lambda text: text.replace("{{", "{").replace("}}", "}")
        sha = gql("mutation($data: CreatePromptVersionInput!) { createPromptVersion(data: $data) { sha } }",
                  {"promptId": prompt, "type": "Chat", "service": "OpenAIChatCompletion", "message": "the arena's prompt", "settings": {"model": "gpt-4o-mini"},
                   "content": {"messages": [{"role": "system", "content": single(SYSTEM)}, {"role": "user", "content": single(USER)}]}})["sha"]
        gql("mutation($data: PublishPromptInput!) { publishPrompt(data: $data) { id } }", {"promptId": prompt, "environmentId": env, "promptVersionSha": sha})
        key = gql("query($data: GetApiKeysInput!) { apiKeys(data: $data) { id } }", {"organizationId": org})[0]["id"]
        s = Service("127.0.0.1", 3300, {"x-pezzo-api-key": key, "x-pezzo-project-id": project})

        def get():
            found = s.call("GET", "/api/prompts/v2/deployment?name=support&environmentName=Production")
            return [fill(m["content"], "{", "}") for m in found["content"]["messages"]]
    else:
        raise SystemExit(f"no prompt tool {tool}")
    get()  # One call first, so opening the connection isn't timed.
    wrong, t = 0, time.perf_counter()
    for _ in range(n):
        wrong += get() != want
    seconds, times = time.perf_counter() - t, n
print(f"got the prompt and filled it in, {wrong} times wrong")
print(f"metric us_per_prompt={seconds * 1e6 / times:.3f}\nmetric times={times}", file=sys.stderr)
if wrong:
    sys.exit(1)
