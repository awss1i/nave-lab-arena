"""Writes a coding agent's session as request bodies, one JSON body a line, for the load tool's --replay.
Usage: gen_session.py OUT.jsonl [TURNS]

The shape is what a coding agent sends: a long system prompt, a few dozen tool definitions, and a history that grows
by a tool call and its result every turn, streamed. The file contents it "reads" are this repo's own scripts, so
the text is real code and nothing private. The stand-in model answers each body with the echo of its last message."""
import glob
import json
import sys

out, turns = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 40
files = sorted(glob.glob("*.sh") + glob.glob("setup/*.sh") + glob.glob("clients/*.py") + glob.glob("clients/*.sh"))
texts = [(f, open(f).read()) for f in files]
system = "You are a coding agent working in a repository. " + " ".join(
    f"Rule {i}: when you {verb}, {rule}." for i in range(1, 90)
    for verb, rule in [("edit a file", "read it first and keep its style"), ("run a command", "say what it does and check its output")][i % 2: i % 2 + 1])
kinds = ["read_file", "write_file", "edit_file", "run_command", "search_files", "list_directory", "git_status", "git_diff", "run_tests", "fetch_url"]
tools = [{"type": "function", "function": {
    "name": f"{kind}_{n}" if n else kind,
    "description": f"{kind.replace('_', ' ').capitalize()} in the working tree. Returns the result as text, cut at 30,000 characters. Fails with a message when the path is outside the repository.",
    "parameters": {"type": "object", "properties": {
        "path": {"type": "string", "description": "A path relative to the repository's root"},
        "pattern": {"type": "string", "description": "A regular expression, when the tool searches"},
        "timeout_ms": {"type": "integer", "minimum": 0, "maximum": 600000},
        "options": {"type": "object", "properties": {"recursive": {"type": "boolean"}, "limit": {"type": "integer"}}}},
        "required": ["path"]}}} for n in range(3) for kind in kinds]
messages = [{"role": "system", "content": system}, {"role": "user", "content": "Find out why the gateway race fails on a slow runner and fix it."}]
with open(out, "w") as f:
    for t in range(turns):
        f.write(json.dumps({"model": "mock", "messages": messages, "tools": tools, "stream": True, "temperature": 0}) + "\n")
        name, text = texts[t % len(texts)]
        call_id = f"call_{t:04d}"
        messages = messages + [
            {"role": "assistant", "content": None, "tool_calls": [{"id": call_id, "type": "function", "function": {"name": "read_file", "arguments": json.dumps({"path": name})}}]},
            {"role": "tool", "tool_call_id": call_id, "content": f"{name} (turn {t})\n{text}"},
        ]
