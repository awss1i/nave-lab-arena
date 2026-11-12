"""Renders a Mustache template with chevron or pystache and prints what Nave's p014 prints for the same file.
Each render does what a gateway does for a call: the variables are read from JSON text, the template is rendered,
and the text is written as a JSON string ready for a request body.
Usage: mustache_render.py chevron|pystache TEMPLATE VARS ITERS."""
import json
import sys
import time

lib, src, vars_text, iters = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read(), int(sys.argv[4])
data = json.loads(vars_text)
MASK = 0xFFFFFFFFFFFFFFFF
if lib == "chevron":
    import chevron

    # chevron reads the template on every render and keeps nothing between renders.
    render = lambda: chevron.render(src, json.loads(vars_text))
    compile_once = lambda: None
else:
    import pystache

    parsed = pystache.parse(src)
    renderer = pystache.Renderer(escape=lambda s: s)
    render = lambda: renderer.render(parsed, json.loads(vars_text))
    compile_once = lambda: pystache.parse(src)
t = time.perf_counter()
for _ in range(max(1, iters // 10)):
    compile_once()
compile_ns = (time.perf_counter() - t) * 1e9 / max(1, iters // 10)
t = time.perf_counter()
for _ in range(iters):
    text = render()
    body = json.dumps(text, ensure_ascii=False)
ns = (time.perf_counter() - t) * 1e9 / iters
h = 0xCBF29CE484222325
for x in text.encode():
    h = ((h ^ x) * 0x100000001B3) & MASK
print(f"{len(text.encode())} bytes, checksum {h:016x}")
print(f"metric ns_per_render={ns:.1f}\nmetric ns_to_compile={compile_ns:.1f}", file=sys.stderr)
