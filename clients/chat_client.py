"""N chat calls on one kept connection through a Python client library, checked and summed the way the load tool does.
Usage: chat_client.py litellm|openai|aisuite|any-llm|langchain|llm URL N [--stream]. URL is the stand-in's base, such as http://127.0.0.1:9000/v1."""
import os
import sys
import time

lib, base, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
stream = "--stream" in sys.argv
key = os.environ.get("LLM_KEY", "local")
MASK = 0xFFFFFFFFFFFFFFFF


def fnv(b):
    h = 0xCBF29CE484222325
    for x in b:
        h = ((h ^ x) * 0x100000001B3) & MASK
    return h


t_import = time.perf_counter()
if lib == "litellm":
    os.environ.setdefault("LITELLM_LOCAL_MODEL_COST_MAP", "True")
    os.environ.setdefault("LITELLM_LOG", "ERROR")
    import litellm

    litellm.telemetry = False
    litellm.suppress_debug_info = True

    def call(i):
        r = litellm.completion(model="openai/mock", api_base=base, api_key=key, messages=[{"role": "user", "content": f"call {i}"}], stream=stream)
        if stream:
            return "".join(c.choices[0].delta.content or "" for c in r)
        return r.choices[0].message.content
elif lib == "aisuite":
    import aisuite

    client = aisuite.Client({"openai": {"api_key": key, "base_url": base, "max_retries": 0}})

    def call(i):
        r = client.chat.completions.create(model="openai:mock", messages=[{"role": "user", "content": f"call {i}"}], stream=stream)
        if stream:
            return "".join((c.choices[0].delta.content or "") for c in r if c.choices)
        return r.choices[0].message.content
elif lib == "any-llm":
    from any_llm import completion

    def call(i):
        r = completion(model="mock", provider="openai", api_key=key, api_base=base, messages=[{"role": "user", "content": f"call {i}"}], stream=stream)
        if stream:
            return "".join((c.choices[0].delta.content or "") for c in r if c.choices)
        return r.choices[0].message.content
elif lib == "langchain":
    from langchain_openai import ChatOpenAI

    chat = ChatOpenAI(model="mock", base_url=base, api_key=key, max_retries=0)

    def call(i):
        if stream:
            return "".join(c.content for c in chat.stream([("user", f"call {i}")]))
        return chat.invoke([("user", f"call {i}")]).content
elif lib == "llm":
    # Simon Willison's llm takes an OpenAI-compatible model from a file in its own folder.
    import tempfile

    home = tempfile.mkdtemp()
    os.environ["LLM_USER_PATH"] = home
    with open(os.path.join(home, "extra-openai-models.yaml"), "w") as f:
        f.write(f"- model_id: mock\n  model_name: mock\n  api_base: \"{base}\"\n")
    import llm

    model = llm.get_model("mock")
    model.key = key

    def call(i):
        return model.prompt(f"call {i}", stream=stream).text()
else:
    from openai import OpenAI

    client = OpenAI(base_url=base, api_key=key, max_retries=0)

    def call(i):
        r = client.chat.completions.create(model="mock", messages=[{"role": "user", "content": f"call {i}"}], stream=stream)
        if stream:
            return "".join((c.choices[0].delta.content or "") for c in r if c.choices)
        return r.choices[0].message.content
import_s = time.perf_counter() - t_import

ok = bad = total = 0
lat = []
t0 = time.perf_counter()
for i in range(n):
    t = time.perf_counter()
    text = call(i)
    lat.append((time.perf_counter() - t) * 1e6)
    if text.startswith(f"echo: call {i}"):
        ok += 1
    else:
        bad += 1
    total ^= (fnv(text.encode()) * (i + 1)) & MASK
s = time.perf_counter() - t0
print(f"ok {ok}\nbad {bad}\nchecksum {total:016x}")
lat.sort()
print(f"metric calls_per_s={n / s:.1f}\nmetric p50_us={lat[len(lat) // 2]:.0f}\nmetric import_ms={import_s * 1e3:.1f}", file=sys.stderr)
sys.exit(1 if bad else 0)
