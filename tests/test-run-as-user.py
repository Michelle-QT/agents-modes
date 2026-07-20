#!/usr/bin/env python3
"""Offline protocol and execution-fidelity checks for agents-run-as-user."""

import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "codex" / "helpers" / "agents-run-as-user"


def request(server, request_id, method, params=None):
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    server.stdin.write(json.dumps(message) + "\n")
    server.stdin.flush()
    return json.loads(server.stdout.readline())


with tempfile.TemporaryDirectory(prefix="agents-run-as-user.") as temporary:
    tmp = pathlib.Path(temporary)
    marker = tmp / "marker"
    snapshot = tmp / "environment"
    snapshot.write_bytes(
        b"SHELL=/bin/sh\0"
        b"HOME=/saved/home\0"
        b"AGENTS_RUN_AS_USER_PROBE=environment-preserved\0"
    )
    server_environment = os.environ.copy()
    server_environment["AGENTS_RUN_AS_USER_PROBE"] = "wrong-server-environment"
    server_environment["OUTER_ONLY"] = "must-not-leak"
    server = subprocess.Popen(
        [str(SERVER), str(snapshot)],
        env=server_environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    initialized = request(
        server,
        1,
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "offline-test", "version": "0"},
        },
    )
    assert initialized["result"]["serverInfo"]["name"] == "agents-run-as-user"
    tools = request(server, 2, "tools/list")
    assert [tool["name"] for tool in tools["result"]["tools"]] == ["run_as_user"]
    command = (
        f"printf marker > {shlex.quote(str(marker))}; "
        "printf '%s|%s|%s|%s' \"$AGENTS_RUN_AS_USER_PROBE\" \"$HOME\" "
        "\"${OUTER_ONLY-unset}\" \"$PWD\"; "
        "printf stderr-preserved >&2; "
        "exit 7"
    )
    called = request(
        server,
        3,
        "tools/call",
        {
            "name": "run_as_user",
            "arguments": {"command": command, "working_directory": str(tmp)},
        },
    )
    result = called["result"]["structuredContent"]
    assert result == {
        "stdout": f"environment-preserved|/saved/home|unset|{tmp}",
        "stderr": "stderr-preserved",
        "exit_status": 7,
        "signal": None,
    }
    assert marker.read_text(encoding="utf-8") == "marker"
    assert marker.stat().st_uid == os.getuid()
    signaled = request(
        server,
        4,
        "tools/call",
        {
            "name": "run_as_user",
            "arguments": {
                "command": "printf signal-output; printf signal-error >&2; kill -TERM $$",
                "working_directory": str(tmp),
            },
        },
    )
    assert signaled["result"]["structuredContent"] == {
        "stdout": "signal-output",
        "stderr": "signal-error",
        "exit_status": None,
        "signal": 15,
    }
    invalid = request(
        server,
        5,
        "tools/call",
        {
            "name": "run_as_user",
            "arguments": {
                "command": "printf should-not-run",
                "working_directory": "relative",
            },
        },
    )
    assert invalid["result"]["isError"] is True
    server.stdin.close()
    assert server.wait(timeout=5) == 0
    assert server.stderr.read() == ""

print("ok - agents-run-as-user protocol and execution fidelity")
