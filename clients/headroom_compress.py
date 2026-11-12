"""Compresses one file with Headroom, as the output of a tool call, the way Headroom sees tool output in a chat.
Usage: headroom_compress.py FILE ITERS. Prints the sizes, and tokens by tiktoken's o200k_base before and after."""
import sys
import time

import tiktoken
from headroom import compress

text = open(sys.argv[1]).read()
iters = int(sys.argv[2])
enc = tiktoken.get_encoding("o200k_base")


def messages():
    return [
        {"role": "user", "content": "Look at this and tell me what matters."},
        {"role": "assistant", "content": None, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "run", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "call_1", "content": text},
        {"role": "user", "content": "Thanks. Now summarise it."},
    ]


result = compress(messages(), model="gpt-4o")
t = time.perf_counter()
for _ in range(iters):
    result = compress(messages(), model="gpt-4o")
s = (time.perf_counter() - t) / iters
out = next(m["content"] for m in result.messages if m.get("role") == "tool")
out = out if isinstance(out, str) else str(out)
print("compressed")
print(f"metric bytes_kept={len(out.encode()) / len(text.encode()):.4f}\nmetric tokens_before={len(enc.encode(text))}\nmetric tokens_after={len(enc.encode(out))}\nmetric mb_per_s={len(text.encode()) / 1e6 / s:.3f}", file=sys.stderr)
if "--show" in sys.argv:
    print(out[:1500])
