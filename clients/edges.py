"""Checks what a gateway does at the edges of the chat API: text that needs escaping, a large body, tools, images,
sampling fields, usage on a stream, an upstream's errors, an unknown model, a broken body, and Anthropic's format.
Usage: edges.py BASE CHAT_PATH MESSAGES_PATH STANDIN_BODY_FILE [--model NAME] [--header "NAME: VALUE"].. [--field NAME=JSON]..

The stand-in model writes the latest request it got to STANDIN_BODY_FILE, so a check can compare what the gateway
sent upstream with what was sent to the gateway. It prints one line a check and the count that passed."""
import hashlib
import http.client
import json
import os
import sys
import urllib.parse

base, chat_path, messages_path, body_file = sys.argv[1:5]
rest = sys.argv[5:]
model = rest[rest.index("--model") + 1] if "--model" in rest else "mock"
extra = dict(h.split(": ", 1) for i, h in enumerate(rest) if i and rest[i - 1] == "--header")
# A gateway's own body fields, such as one that needs "stream": false said out loud. A check's own value wins.
fields = dict((f.split("=", 1)[0], json.loads(f.split("=", 1)[1])) for i, f in enumerate(rest) if i and rest[i - 1] == "--field")
key = os.environ.get("LLM_KEY", "local")
host = urllib.parse.urlparse(base).netloc


def post(path, body, anthropic=False, raw=None):
    """One call on a connection of its own. Returns the status and the body's bytes, or a reason it failed."""
    headers = {"content-type": "application/json", **extra}
    headers.update({"x-api-key": key, "anthropic-version": "2023-06-01"} if anthropic else {"authorization": f"Bearer {key}"})
    try:
        c = http.client.HTTPConnection(host, timeout=20)
        c.request("POST", path, raw if raw is not None else json.dumps({**fields, **body} if isinstance(body, dict) else body).encode(), headers)
        r = c.getresponse()
        return r.status, r.read()
    except (OSError, http.client.HTTPException) as e:
        return 0, f"no answer: {type(e).__name__}".encode()
    finally:
        c.close()


def upstream():
    """The request body the stand-in got last."""
    try:
        return json.loads(open(body_file, "rb").read().split(b"\n\n", 1)[1])
    except (OSError, IndexError, ValueError):
        return {}


def answer(raw):
    try:
        return json.loads(raw)["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def chat(messages, **more):
    return {"model": model, "messages": messages, **more}


def user(text):
    return [{"role": "user", "content": text}]


checks = []


def check(name):
    def wrap(f):
        checks.append((name, f))
        return f
    return wrap


@check("text with quotes, backslashes, new lines, other scripts and emoji comes back the same")
def _():
    text = 'héllo "quoted" \\ back\nline two\ttab 日本語 😀 </script>   end'
    status, raw = post(chat_path, chat(user(text)))
    return status == 200 and answer(raw) == f"echo: {text}", f"status {status}"


@check("a message of one megabyte goes through whole")
def _():
    text = "the quick brown fox jumps over the lazy dog. " * 22223
    status, raw = post(chat_path, chat(user(text)))
    got = answer(raw) or ""
    return status == 200 and hashlib.sha256(got.encode()).hexdigest() == hashlib.sha256(f"echo: {text}".encode()).hexdigest(), f"status {status}, {len(got)} characters back"


@check("tools and tool_choice reach the model unchanged")
def _():
    tools = [{"type": "function", "function": {"name": "get_weather", "description": "Weather for a city", "parameters": {"type": "object", "properties": {"city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}}, "required": ["city"]}}}]
    choice = {"type": "function", "function": {"name": "get_weather"}}
    status, raw = post(chat_path, chat(user("tools"), tools=tools, tool_choice=choice))
    up = upstream()
    return status == 200 and up.get("tools") == tools and up.get("tool_choice") == choice, f"status {status}"


@check("an image part reaches the model unchanged")
def _():
    content = [{"type": "text", "text": "look"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "detail": "low"}}]
    status, raw = post(chat_path, chat([{"role": "user", "content": content}]))
    up = upstream()
    return status == 200 and (up.get("messages") or [{}])[-1].get("content") == content, f"status {status}"


@check("temperature, top_p, max_tokens, stop, seed, response_format and user reach the model unchanged")
def _():
    fields = {"temperature": 0.3, "top_p": 0.9, "max_tokens": 77, "stop": ["END"], "seed": 7, "response_format": {"type": "json_object"}, "user": "u-1"}
    status, raw = post(chat_path, chat(user("fields"), **fields))
    up = upstream()
    lost = [k for k, v in fields.items() if up.get(k) != v]
    return status == 200 and not lost, f"status {status}, changed or lost: {', '.join(lost) or 'none'}"


@check("a stream asked for usage ends with it, and its text is whole")
def _():
    status, raw = post(chat_path, chat(user("stream me"), stream=True, stream_options={"include_usage": True}))
    text, usage = "", None
    for line in raw.decode("utf-8", "replace").splitlines():
        if line.startswith("data: ") and line != "data: [DONE]":
            try:
                v = json.loads(line[6:])
            except ValueError:
                continue
            for ch in v.get("choices") or []:
                text += (ch.get("delta") or {}).get("content") or ""
            usage = v.get("usage") or usage
    return status == 200 and text == "echo: stream me" and bool(usage and usage.get("total_tokens")), f"status {status}, text {text!r}, usage {usage}"


@check("a history with a tool call and its result goes through")
def _():
    messages = user("read it") + [{"role": "assistant", "content": None, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"a.txt\"}"}}]},
                                  {"role": "tool", "tool_call_id": "call_1", "content": "the file's text"}]
    status, raw = post(chat_path, chat(messages))
    up = upstream()
    return status == 200 and answer(raw) == "echo: the file's text" and (up.get("messages") or [{}, {}])[-2].get("tool_calls") == messages[1]["tool_calls"], f"status {status}"


@check("the model's 429 comes back as a 429")
def _():
    status, raw = post(chat_path, chat(user("standin-status 429")))
    return status == 429, f"status {status}"


@check("the model's 400 comes back as a 400")
def _():
    status, raw = post(chat_path, chat(user("standin-status 400")))
    return status == 400, f"status {status}"


@check("a model that isn't routed gets a 4xx")
def _():
    status, raw = post(chat_path, {"model": "no-such-model-anywhere", "messages": user("hello")})
    return 400 <= status < 500, f"status {status}"


@check("a body that isn't JSON gets a 4xx")
def _():
    status, raw = post(chat_path, None, raw=b'{"model": "mock", "messages": [')
    return 400 <= status < 500, f"status {status}"


@check("a call in Anthropic's format gets an answer in Anthropic's format")
def _():
    status, raw = post(messages_path, {"model": model, "max_tokens": 64, "messages": user("hi there")}, anthropic=True)
    try:
        v = json.loads(raw)
        return status == 200 and v["type"] == "message" and v["content"][0]["text"] == "echo: hi there" and "input_tokens" in v["usage"], f"status {status}"
    except (ValueError, KeyError, IndexError, TypeError):
        return False, f"status {status}"


@check("a stream in Anthropic's format has its text and ends with message_stop")
def _():
    status, raw = post(messages_path, {"model": model, "max_tokens": 64, "stream": True, "messages": user("hi stream")}, anthropic=True)
    text, events = "", []
    for line in raw.decode("utf-8", "replace").splitlines():
        if line.startswith("event: "):
            events.append(line[7:].strip())
        if line.startswith("data: "):
            try:
                text += (json.loads(line[6:]).get("delta") or {}).get("text") or ""
            except ValueError:
                pass
    return status == 200 and text == "echo: hi stream" and events[-1:] == ["message_stop"], f"status {status}, text {text!r}"


# The check that makes the model answer 429 runs last: some gateways rest a provider after its 429, and the
# checks after it would then fail for that reason and not their own.
checks.sort(key=lambda c: "429" in c[0])
passed = 0
for name, f in checks:
    try:
        ok, why = f()
    except Exception as e:  # A check that throws is a failed check, with the reason kept.
        ok, why = False, f"{type(e).__name__}: {e}"
    passed += bool(ok)
    print(f"{'pass' if ok else 'FAIL'}  {name}" + ("" if ok else f" ({why})"))
print(f"{passed} of {len(checks)} passed")
print(f"metric edges_passed={passed}\nmetric edges_total={len(checks)}", file=sys.stderr)
