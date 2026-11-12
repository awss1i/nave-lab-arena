"""Writes the race file for one gateway against Nave, for the harness. Every gateway gets the same races, less the
kinds its setup file says it can't run.
Usage: gen.py NAME TITLE "SKIPPED KINDS" "NAVE'S FEATURES" "ITS FEATURES" > run/gw-NAME.json"""
import json
import sys

name, title, skip, nave_on, its_on = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4], sys.argv[5]
# A gateway that takes only Anthropic's format gets every race in that format, and the races written for
# OpenAI's format alone are left out.
anthropic_only = len(sys.argv) > 6 and sys.argv[6] == "messages"
if anthropic_only:
    skip += ["messages", "replay", "edges"]
both = f"nave {name}"
# A gateway that answers under about a hundred calls a second can't finish the whole job inside a runner's time
# limit. Its setup file says so with the word "slow" among its skipped kinds, and its job is cut down: one round a
# race, 2,000 calls before memory is read, and no race at 1,000 calls a second, which it could only queue.
slow = "slow" in skip
if slow:
    skip = [k for k in skip if k != "slow"] + ["rate1000"]
ground = "a GitHub runner's four CPUs: the load tool on one, the stand-in model on one, the gateway on two"
on = f". Switched on in Nave: {nave_on}. Switched on in {title}: {its_on}"


def race(kind, text, conditions, cmd, rounds=5, mode="", with_direct=False, env="", feature="F1 and F13", gateways=both):
    if kind in skip:
        return None
    if slow:
        rounds = 1
    entrants = [{"name": "Nave", "cmd": ["./gateways.sh"] + [c.replace("NAME", "nave") for c in cmd]}, {"name": title, "cmd": ["./gateways.sh"] + [c.replace("NAME", name) for c in cmd]}]
    if with_direct:
        entrants.insert(0, {"name": "No gateway", "cmd": ["./gateways.sh"] + [c.replace("NAME", "direct") for c in cmd]})
    up = f"{env} ./gateways.sh up '{gateways}' {mode}".strip()
    return {"name": text, "feature": feature, "conditions": conditions + on, "rounds": rounds, "normalise": "lines", "entrants": entrants,
            "setup": ["sh", "-c", up], "teardown": ["./gateways.sh", "down", gateways]}


def alone(kind, text, conditions, cmd, who, mode="", feature="F1"):
    """A race with one entrant, for a measure that isn't a time and whose output differs by tool."""
    if kind in skip and who != "nave":
        return None
    label = "Nave" if who == "nave" else title
    return {"name": f"{text}, {label}", "feature": feature, "conditions": conditions, "rounds": 1, "normalise": "lines",
            "entrants": [{"name": label, "cmd": ["./gateways.sh"] + [c.replace("NAME", who) for c in cmd]}],
            "setup": ["sh", "-c", f"./gateways.sh up '{who}' {mode}".strip()], "teardown": ["./gateways.sh", "down", who]}


races = [
    race("kept", "200 calls on one kept connection", ground + ", OpenAI's format in and out", ["load", "NAME", "--calls", "200", "--conns", "1"], rounds=7),
    race("many", "2,000 calls over 64 connections", ground + ", OpenAI's format in and out", ["load", "NAME", "--calls", "2000", "--conns", "64"]),
    race("history", "500 calls with 50 KB of history over 16 connections", ground + ", OpenAI's format in and out", ["load", "NAME", "--calls", "500", "--conns", "16", "--history", "50000"]),
    race("stream", "500 streamed calls over 16 connections", ground + ", OpenAI's format in and out", ["load", "NAME", "--calls", "500", "--conns", "16", "--stream"]),
    race("many", "2,000 calls over 64 connections, the client acknowledging at once", ground + ", OpenAI's format in and out, the load tool acknowledging every packet at once where an ordinary client waits up to 40 ms", ["quick", "NAME", "--calls", "2000", "--conns", "64"]),
    race("stream", "500 streamed calls over 16 connections, the client acknowledging at once", ground + ", OpenAI's format in and out, the load tool acknowledging every packet at once where an ordinary client waits up to 40 ms", ["quick", "NAME", "--calls", "500", "--conns", "16", "--stream"]),
    race("messages", "500 calls in Anthropic's format over 16 connections", ground + ", Anthropic's format in and OpenAI's format to the model", ["messages", "NAME", "--calls", "500", "--conns", "16"]),
    race("rate", "500 calls at 50 a second", ground + ", calls sent at a fixed rate over 16 connections whatever the answers do, each timed from when it was due", ["rate", "NAME", "50", "500", "16"], rounds=3, with_direct=True),
    race("rate1000" if slow else "rate", "5,000 calls at 1,000 a second", ground + ", calls sent at a fixed rate over 64 connections whatever the answers do, each timed from when it was due", ["rate", "NAME", "1000", "5000", "64"], rounds=3, with_direct=True),
    race("open", "500 calls open at once on a model that takes half a second", ground + ", 1,000 calls over 500 connections, the memory read one second in", ["open", "NAME", "500", "1000"], rounds=3, env="STANDIN_ARGS='--first-ms 500'"),
    race("fallback", "500 calls over 16 connections while the first provider answers 500", ground + ", each gateway given the failing provider first and the working one second", ["load", "NAME", "--calls", "500", "--conns", "16"], mode="fallback", feature="F3"),
    race("onecpu", "2,000 calls over 64 connections with the gateway on one CPU", "a GitHub runner's CPUs: the load tool on one, the stand-in model on one, the gateway on one", ["load", "NAME", "--calls", "2000", "--conns", "64"], env="ONE_CPU=1"),
    race("replay", "a coding agent's session of 40 turns, replayed on 4 connections", ground + ", every turn streamed, with 30 tools and a history that grows from 26 KB to 108 KB", ["replay", "NAME", "4"], rounds=3),
    race("cache", "2,000 repeats of one call over 16 connections, with each gateway's cache on", ground + ", the same message every time, each gateway's own in-memory cache switched on, and the number of calls that still reached the model counted", ["cached", "NAME", "--calls", "2000", "--conns", "16", "--same"], mode="cache", feature="F5"),
    race("fresh", "one call through a gateway started for it", ground + ", each gateway started by its own start command and stopped after the call", ["fresh", "NAME"], gateways="", env=f"STANDIN_FOR='{both}'"),
    race("memory", f"memory held after {'2,000' if slow else '20,000'} calls over 64 connections", ground, ["memory", "NAME"] + (["2000"] if slow else []), rounds=1),
    alone("edges", "the API's edges, 13 checks", "one call a check, what the model received compared with what was sent", ["edges", "NAME"], "nave", mode="edges"),
    alone("edges", "the API's edges, 13 checks", "one call a check, what the model received compared with what was sent", ["edges", "NAME"], name, mode="edges"),
]
# A gateway's own published benchmark, rerun here with Nave in it. Its setup file gives it as
# "RATE CALLS CONNS|STAND-IN OPTIONS|what the benchmark is".
own = sys.argv[7] if len(sys.argv) > 7 else ""
if own:
    load, standin, text = own.split("|", 2)
    rate, calls, conns = load.split()
    # The client acknowledges every packet at once here, so a gateway's own benchmark isn't held back by the
    # 40 ms an ordinary client waits, which its own load generator may not have had.
    races.append(race("own", f"{title}'s own benchmark, rerun", ground + ", " + text + f", sent here at {int(rate):,} calls a second over {conns} connections by a client that acknowledges every packet at once, each call timed from when it was due",
                      ["quickrate", "NAME", rate, calls, conns], rounds=3, mode="own", with_direct=True, env=f"STANDIN_ARGS='{standin}'" if standin else ""))
races = [r for r in races if r]
if anthropic_only:
    for r in races:
        r["conditions"] = r["conditions"].replace("OpenAI's format in and out", "Anthropic's format in and OpenAI's format to the model").replace(ground + ". ", ground + ", Anthropic's format in and OpenAI's format to the model. ", 1) if "format" not in r["conditions"].split(". Switched on")[0] else r["conditions"].replace("OpenAI's format in and out", "Anthropic's format in and OpenAI's format to the model")
        r["name"] += ", in Anthropic's format"
json.dump(races, sys.stdout, indent=1)
