"""Prints one file compressed by a prompt compressor, for counting its tokens and asking questions of it.
Usage: compress_text.py headroom|headroom-ml|llmlingua2 FILE [RATE]

headroom is Headroom's `compress` as installed. headroom-ml is the same with its learned text compressor, Kompress,
which the `ml` extra installs and which downloads its model on first use. llmlingua2 is LLMLingua-2 with its small
model, keeping RATE of the tokens (0.5 when not given). The text is given to Headroom as the output of a tool call,
further back than the four latest messages it protects, which is how Headroom sees tool output in a chat."""
import sys
import warnings

warnings.filterwarnings("ignore")
tool, path = sys.argv[1], sys.argv[2]
text = open(path).read()
if tool in ("headroom", "headroom-ml"):
    from headroom import CompressConfig, compress

    messages = [{"role": "user", "content": "Look at this and tell me what matters."},
                {"role": "assistant", "content": None, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "run", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "call_1", "content": text}]
    for i in range(3):
        messages += [{"role": "assistant", "content": f"Noted, step {i}."}, {"role": "user", "content": f"Go on with step {i + 1}."}]
    config = CompressConfig() if tool == "headroom-ml" else CompressConfig(kompress_model="disabled")
    out = next(m["content"] for m in compress(messages, model="gpt-4o", config=config).messages if m.get("role") == "tool")
    sys.stdout.write(out if isinstance(out, str) else str(out))
elif tool == "llmlingua2":
    from llmlingua import PromptCompressor

    rate = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    compressor = PromptCompressor(model_name="microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank", use_llmlingua2=True, device_map="cpu")
    sys.stdout.write(compressor.compress_prompt(text, rate=rate, force_tokens=["\n"])["compressed_prompt"])
else:
    raise SystemExit(f"no compressor {tool}")
