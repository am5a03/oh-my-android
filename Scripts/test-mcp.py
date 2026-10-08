#!/usr/bin/env python3
"""Device-free wire-protocol tests. No valid mutating calls are issued."""
import json
import subprocess
import sys

MODERN = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print("FAIL", message)


def session(server, messages):
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    result = subprocess.run([server], input=lines, capture_output=True, text=True, timeout=30)
    check(result.returncode == 0, f"server failed: {result.stderr[:300]}")
    responses = {}
    for line in result.stdout.splitlines():
        message = json.loads(line)
        check(message.get("jsonrpc") == "2.0", f"not JSON-RPC: {line[:80]}")
        responses[message.get("id")] = message
    return responses


def main(server):
    legacy = session(server, [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "prompts/list"},
        {"jsonrpc": "2.0", "id": 4, "method": "prompts/get", "params": {"name": "debug_crash", "arguments": {"package": "com.example"}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "no_such_tool", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 6, "method": "ping"},
        {"jsonrpc": "2.0", "id": 7, "method": "no/such/method"},
        {"jsonrpc": "2.0", "id": 8, "method": "initialize", "params": {"protocolVersion": "2099-01-01", "capabilities": {}}},
        {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "screenshot", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "manage_app", "arguments": {"action": "clear_data"}}},
    ])
    init = legacy[1]["result"]
    check(init["protocolVersion"] == "2025-06-18", "supported legacy version")
    check(legacy[8]["result"]["protocolVersion"] == "2025-11-25", "legacy version fallback")
    check(init["serverInfo"]["name"] == "oh-my-android", "server name")
    check("resultType" not in init, "legacy response format")
    check(legacy[9]["result"].get("isError") is True, "missing screenshot target refused")
    check(legacy[10]["result"].get("isError") is True, "incomplete destructive call refused")
    tools = legacy[2]["result"]["tools"]
    names = [t["name"] for t in tools]
    check(len(names) == len(set(names)), "unique names")
    check(len(tools) == 19, f"19 tools, got {len(tools)}")
    check("get_app_target" in names, "explicit target discovery available")
    for tool in tools:
        schema = tool["inputSchema"]
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        check(schema.get("type") == "object", f"{tool['name']}: object schema")
        check(required <= set(props), f"{tool['name']}: required names exist")
        if "device" in props:
            check("device" in required, f"{tool['name']}: explicit device required")
        if tool["name"] in ("open_app", "manage_app"):
            check({"package", "user_id", "device"} <= required, f"{tool['name']}: complete app target required")
        if tool["name"] in ("read_preferences", "query_database"):
            check("package" in required, f"{tool['name']}: no foreground fallback")
        for name, prop in props.items():
            check("type" in prop and prop.get("description"), f"{tool['name']}.{name}: type/description")
        check(isinstance(tool["annotations"].get("readOnlyHint"), bool), "read annotation")
        check(tool["description"] and len(tool["description"]) < 400, "compact description")
    size = sum(len(json.dumps({k: t[k] for k in ("name", "description", "inputSchema")}, separators=(",", ":"))) for t in tools)
    check(size < 18000, f"compact tool definitions ({size})")
    check(len(legacy[3]["result"]["prompts"]) == 3, "3 prompts")
    check("com.example" in legacy[4]["result"]["messages"][0]["content"]["text"], "prompt substitution")
    check(legacy[5]["error"]["code"] == -32602, "unknown tool")
    check(legacy[6]["result"] == {}, "ping")
    check(legacy[7]["error"]["code"] == -32601, "unknown method")
    modern = session(server, [
        {"jsonrpc": "2.0", "id": "d", "method": "server/discover", "params": {"_meta": MODERN}},
        {"jsonrpc": "2.0", "id": "t", "method": "tools/list", "params": {"_meta": MODERN}},
        {"jsonrpc": "2.0", "id": "v", "method": "tools/list", "params": {"_meta": {**MODERN, "io.modelcontextprotocol/protocolVersion": "1999-01-01"}}},
        {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "unknown"}},
        "not json",
    ])
    discover = modern["d"]["result"]
    check(discover["supportedVersions"] == ["2026-07-28"], "modern versions")
    check(discover["resultType"] == "complete", "modern result type")
    check(discover["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "oh-my-android", "modern serverInfo")
    listed = modern["t"]["result"]
    check(listed["ttlMs"] > 0 and listed["cacheScope"] == "public", "cacheable lists")
    check([t["name"] for t in listed["tools"]] == names, "stable tool order")
    check(modern["v"]["error"]["code"] == -32022, "unsupported version")
    check(modern["v"]["error"]["data"]["requested"] == "1999-01-01", "version error details")
    check(modern[None]["error"]["code"] == -32700, "parse error")
    help_text = subprocess.run([server, "--help"], capture_output=True, text=True, timeout=10).stdout
    check("claude mcp add" in help_text, "help setup")
    print(f"{len(tools)} tools, {size} chars of definitions. " + ("FAILED" if failures else "All checks passed."))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main(sys.argv[1])
