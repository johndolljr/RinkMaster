#!/usr/bin/env python3
"""Talks to rinkmaster-mcp over stdio like an agent would and prints each answer.

Usage: scripts/mcp-smoke.py [binary] tool[=json-args] ...
  e.g. scripts/mcp-smoke.py overview 'search_games={"text":"galaga"}'
"""
import json, subprocess, sys, os

args = sys.argv[1:]
binary = args.pop(0) if args and os.path.exists(args[0]) else os.path.join(os.path.dirname(__file__), "..", ".build", "debug", "rinkmaster-mcp")
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
n = 0
def rpc(method, params=None, notify=False):
    global n
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None: msg["params"] = params
    if not notify:
        n += 1; msg["id"] = n
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    return None if notify else json.loads(p.stdout.readline())

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
print("server:", init["result"]["serverInfo"], "protocol", init["result"]["protocolVersion"])
rpc("notifications/initialized", notify=True)
tools = rpc("tools/list")["result"]["tools"]
print("tools (%d):" % len(tools), " ".join(t["name"] for t in tools))
for spec in args:
    name, _, raw = spec.partition("=")
    r = rpc("tools/call", {"name": name, "arguments": json.loads(raw) if raw else {}})["result"]
    text = r["content"][0]["text"]
    print("\n== %s%s -> %s" % (name, " " + raw if raw else "", "ERROR" if r["isError"] else "ok"))
    print(text if len(text) < 3500 else text[:3500] + "\n... (%d more chars)" % (len(text) - 3500))
p.stdin.close(); p.wait(timeout=10)
