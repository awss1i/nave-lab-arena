"""Writes the race file for one gateway against Nave, for the harness. Every gateway gets the same races, less the
kinds its setup file says it can't run.
Usage: gen.py NAME TITLE "SKIPPED KINDS" "NAVE'S FEATURES" "ITS FEATURES" > run/gw-NAME.json"""
import json
import sys

name, title, skip, nave_on, its_on = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4], sys.argv[5]
both = f"nave {name}"
ground = "a GitHub runner's four CPUs: the load tool on one, the stand-in model on one, the gateway on two"
on = f". Switched on in Nave: {nave_on}. Switched on in {title}: {its_on}"


def race(kind, text, conditions, cmd, rounds=5, mode="", with_direct=False, env="", feature="F1 and F13", gateways=both):
    if kind in skip:
        return None
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
    race("rate", "5,000 calls at 1,000 a second", ground + ", calls sent at a fixed rate over 64 connections whatever the answers do, each timed from when it was due", ["rate", "NAME", "1000", "5000", "64"], rounds=3, with_direct=True),
    race("open", "500 calls open at once on a model that takes half a second", ground + ", 1,000 calls over 500 connections, the memory read one second in", ["open", "NAME", "500", "1000"], rounds=3, env="STANDIN_ARGS='--first-ms 500'"),
    race("fallback", "500 calls over 16 connections while the first provider answers 500", ground + ", each gateway given the failing provider first and the working one second", ["load", "NAME", "--calls", "500", "--conns", "16"], mode="fallback", feature="F3"),
    race("onecpu", "2,000 calls over 64 connections with the gateway on one CPU", "a GitHub runner's CPUs: the load tool on one, the stand-in model on one, the gateway on one", ["load", "NAME", "--calls", "2000", "--conns", "64"], env="ONE_CPU=1"),
    race("replay", "a coding agent's session of 40 turns, replayed on 4 connections", ground + ", every turn streamed, with 30 tools and a history that grows from 26 KB to 108 KB", ["replay", "NAME", "4"], rounds=3),
    race("cache", "2,000 repeats of one call over 16 connections, with each gateway's cache on", ground + ", the same message every time, each gateway's own in-memory cache switched on, and the number of calls that still reached the model counted", ["cached", "NAME", "--calls", "2000", "--conns", "16", "--same"], mode="cache", feature="F5"),
    race("fresh", "one call through a gateway started for it", ground + ", each gateway started by its own start command and stopped after the call", ["fresh", "NAME"], gateways=""),
    race("memory", "memory held after 20,000 calls over 64 connections", ground, ["memory", "NAME"], rounds=1),
    alone("edges", "the API's edges, 13 checks", "one call a check, what the model received compared with what was sent", ["edges", "NAME"], "nave", mode="edges"),
    alone("edges", "the API's edges, 13 checks", "one call a check, what the model received compared with what was sent", ["edges", "NAME"], name, mode="edges"),
]
json.dump([r for r in races if r], sys.stdout, indent=1)
