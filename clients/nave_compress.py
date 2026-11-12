"""Compresses one file with Nave's P016 and counts tokens the way headroom_compress.py does.
Usage: nave_compress.py FILE ITERS."""
import subprocess
import sys

import tiktoken

text = open(sys.argv[1]).read()
enc = tiktoken.get_encoding("o200k_base")
out = subprocess.run(["bin/p016", "compress", sys.argv[1]], capture_output=True, text=True, check=True).stdout
bench = subprocess.run(["bin/p016", "bench", sys.argv[1], sys.argv[2]], capture_output=True, text=True, check=True).stderr
speed = next(l.split("=")[1] for l in bench.splitlines() if l.startswith("metric mb_per_s="))
print("compressed")
print(f"metric bytes_kept={len(out.encode()) / len(text.encode()):.4f}\nmetric tokens_before={len(enc.encode(text))}\nmetric tokens_after={len(enc.encode(out))}\nmetric mb_per_s={speed}", file=sys.stderr)
