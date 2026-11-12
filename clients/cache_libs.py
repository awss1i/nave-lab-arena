"""Answers repeated prompts through a cache, the way each tool is meant to be used, and times the repeats.
Usage: cache_libs.py TOOL [PROMPTS]. The stand-in model is on port 9000 and writes each call it gets to the file
named by STANDIN_CALLS, so the calls that reached the model in the second pass can be counted.

One Python client does the same thing for every tool: it asks PROMPTS different questions (the first pass, which
fills the cache), then asks every one of them again (the second pass, which is timed and should never reach the
model), then asks PROMPTS questions the cache has never seen (which all should reach the model).
- nave: OpenAI's SDK pointed at Nave's gateway with its cache on. The cache is the gateway's.
- gptcache: GPTCache's own get and put, with its default ONNX embedding, SQLite and FAISS, as its README sets it
  up. On a miss the client calls the model with OpenAI's SDK and puts the answer.
- redisvl: redis-vl's SemanticCache on Redis with its default local vectorizer. On a miss the client calls the
  model and stores the answer.
- modelcache: ModelCache's demo service over HTTP, with SQLite, FAISS and its text2vec model.
The caches that match by meaning are also asked a reworded form of each first-pass question, and how many of
those they answered from the cache is printed as it is: Nave's gateway cache matches exactly and answers none."""
import os
import sys
import time

tool = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 500
calls_file = os.environ.get("STANDIN_CALLS", "run/standin-calls.log")
keep = os.dup(1)
os.dup2(os.open(os.devnull, os.O_WRONLY), 1)

from openai import OpenAI  # noqa: E402

topics = ["the tide table for a harbour", "a recipe that feeds twelve", "the rules of a card game", "a train timetable", "a packing list for winter", "the plot of a short story",
          "a budget for a school fair", "the care of a fig tree", "a walking route across a city", "the history of a bridge"]
ask = lambda i: f"Question {i}: write three sentences about {topics[i % len(topics)]}, numbered {i * 7919 % 100003}."
reword = lambda i: f"Question {i}: please write 3 sentences on {topics[i % len(topics)]}, with the number {i * 7919 % 100003}."
reached = lambda: sum(1 for _ in open(calls_file)) if os.path.exists(calls_file) else 0


def model(base):
    client = OpenAI(base_url=base, api_key="sk-standin", max_retries=0)
    return lambda prompt: client.chat.completions.create(model="mock", messages=[{"role": "user", "content": prompt}]).choices[0].message.content


if tool == "nave":
    answer = model("http://127.0.0.1:4000/v1")
elif tool == "gptcache":
    from gptcache import Cache
    from gptcache.adapter.api import get, put
    from gptcache.embedding import Onnx
    from gptcache.manager import CacheBase, VectorBase, get_data_manager
    from gptcache.processor.pre import get_prompt
    from gptcache.similarity_evaluation.distance import SearchDistanceEvaluation

    folder = os.environ.get("CACHE_DIR", "run/cache-gptcache")
    os.makedirs(folder, exist_ok=True)
    for f in ("sqlite.db", "faiss.index"):
        if os.path.exists(os.path.join(folder, f)):
            os.remove(os.path.join(folder, f))
    onnx = Onnx()
    cache = Cache()
    cache.init(pre_embedding_func=get_prompt, embedding_func=onnx.to_embeddings,
               data_manager=get_data_manager(CacheBase("sqlite", sql_url=f"sqlite:///{folder}/sqlite.db"), VectorBase("faiss", dimension=onnx.dimension, index_path=f"{folder}/faiss.index")),
               similarity_evaluation=SearchDistanceEvaluation())
    ask_model = model("http://127.0.0.1:9000/v1")

    def answer(prompt):
        hit = get(prompt, cache_obj=cache)
        if hit is not None:
            return hit
        out = ask_model(prompt)
        put(prompt, out, cache_obj=cache)
        return out
elif tool == "redisvl":
    from redisvl.extensions.cache.llm import SemanticCache

    cache = SemanticCache(name="arena", redis_url="redis://127.0.0.1:6389", distance_threshold=0.1)
    cache.clear()
    ask_model = model("http://127.0.0.1:9000/v1")

    def answer(prompt):
        hit = cache.check(prompt=prompt)
        if hit:
            return hit[0]["response"]
        out = ask_model(prompt)
        cache.store(prompt=prompt, response=out)
        return out
elif tool == "modelcache":
    # ModelCache's demo service at its latest tagged release, with SQLite, FAISS and its text2vec embedding model,
    # started by clients/cache_servers.sh. The client asks it over HTTP as its README shows: a query, and on a miss
    # a call to the model and an insert.
    import json
    import urllib.request

    def service(body):
        request = urllib.request.Request("http://127.0.0.1:5000/modelcache", json.dumps(json.dumps(body)).encode(), {"content-type": "application/json"})
        with urllib.request.urlopen(request, timeout=120) as r:
            return json.loads(r.read())

    scope = {"model": "mock"}
    service({"type": "remove", "scope": scope, "remove_type": "truncate_by_model"})
    ask_model = model("http://127.0.0.1:9000/v1")

    def answer(prompt):
        query = [{"role": "user", "content": prompt}]
        found = service({"type": "query", "scope": scope, "query": query})
        if found.get("cacheHit"):
            return found["answer"]
        out = ask_model(prompt)
        service({"type": "insert", "scope": scope, "chat_info": [{"query": query, "answer": out}]})
        return out
else:
    raise SystemExit(f"no cache {tool}")

wrong = 0
for i in range(n):
    wrong += answer(ask(i)) != f"echo: {ask(i)}"
before = reached()
t = time.perf_counter()
for i in range(n):
    wrong += answer(ask(i)) != f"echo: {ask(i)}"
seconds = time.perf_counter() - t
second_pass = reached() - before
before = reached()
reworded = 0
if tool != "nave":
    for i in range(n):
        answer(reword(i))
    reworded = n - (reached() - before)
before = reached()
for i in range(n, 2 * n):
    wrong += answer(ask(i)) != f"echo: {ask(i)}"
unseen_missed = n - (reached() - before)
sys.stdout.flush()
os.dup2(keep, 1)
print(f"answered {3 * n} questions")
print(f"metric us_per_repeat={seconds * 1e6 / n:.1f}\nmetric wrong_answers={wrong}\nmetric repeats_that_reached_the_model={second_pass}\nmetric reworded_answered_from_cache={reworded}\nmetric unseen_answered_from_cache={unseen_missed}", file=sys.stderr)
