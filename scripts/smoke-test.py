import json
import pathlib
import selectors
import sqlite3
import subprocess
import tempfile


project = pathlib.Path(__file__).resolve().parent.parent
binary = project / "dist/AgentTrail.app/Contents/MacOS/AgentTrail"

for notice in ("LICENSE", "THIRD_PARTY.md", "PRIVACY.md"):
    assert (binary.parent.parent / "Resources" / notice).read_bytes() == (project / notice).read_bytes()


def run(*arguments, data=None):
    result = subprocess.run(
        [str(binary), *arguments],
        input=data,
        text=True,
        capture_output=True,
        check=True,
        timeout=30,
    )
    return result.stdout


with tempfile.TemporaryDirectory(prefix="agenttrail-smoke-") as directory:
    root = pathlib.Path(directory) / "library"
    session = json.loads(run("demo", "--root", str(root)))
    session_id = session["id"]
    assert session["eventCount"] == 245
    assert session["actionCount"] == 14
    assert session["metadata"]["synthetic"] == "true"
    actions = json.loads(run("timeline", session_id, "⌘D", "--root", str(root)))
    assert len(actions) == 1
    assert actions[0]["firstEventID"] == 95
    assert "not verified" in actions[0]["inference"]
    export = pathlib.Path(directory) / "dataset"
    run("export", session_id, str(export), "--root", str(root))
    for name, expected in (("events", 245), ("actions", 14), ("training", 14)):
        lines = (export / f"{name}.jsonl").read_text().splitlines()
        assert len(lines) == expected
        records = [json.loads(line) for line in lines]
        if name == "training":
            assert all(record["source"] == "synthetic_example" for record in records)
            assert all(record["outcomeVerified"] is False for record in records)
    raw = [json.loads(line) for line in run("raw", session_id, "--root", str(root)).splitlines()]
    followed = [json.loads(line) for line in run("raw", session_id, "--follow", "--root", str(root)).splitlines()]
    assert len(raw) == 245
    assert raw == followed
    assert raw[0]["id"] == 1 and raw[-1]["id"] == 245
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_actions", "arguments": {"session_id": session_id, "query": "⌘D"}}},
        [
            {"jsonrpc": "2.0", "id": 4, "method": "ping"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ],
    ]
    input_data = "\n".join(json.dumps(request) for request in requests) + "\n"
    database = root / "library.sqlite"
    before = database.stat().st_mtime_ns
    responses = [json.loads(line) for line in run("--mcp", "--root", str(root), data=input_data).splitlines()]
    assert len(responses) == 4
    assert responses[0]["result"]["protocolVersion"] == "2025-03-26"
    assert len(responses[1]["result"]["tools"]) == 3
    assert responses[2]["result"]["isError"] is False
    assert responses[3][0]["id"] == 4
    assert database.stat().st_mtime_ns == before
    assert database.stat().st_mode & 0o777 == 0o600

    connection = sqlite3.connect(database)
    session["status"] = "paused"
    connection.execute("UPDATE sessions SET json=? WHERE id=?", (json.dumps(session), session_id))
    connection.commit()
    follower = subprocess.Popen(
        [str(binary), "raw", session_id, "--follow", "--root", str(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(follower.stdout, selectors.EVENT_READ)
            assert selector.select(timeout=5), "Follower did not emit the initial log"
        appended = dict(raw[-1], id=0, kind="marker", text="Follow-up sample")
        connection.execute(
            "INSERT INTO events(session_id,timestamp,kind,json) VALUES(?,?,?,?)",
            (session_id, appended["timestamp"], appended["kind"], json.dumps(appended)),
        )
        session["status"] = "complete"
        connection.execute("UPDATE sessions SET json=? WHERE id=?", (json.dumps(session), session_id))
        connection.commit()
        output, errors = follower.communicate(timeout=5)
        assert follower.returncode == 0, errors.decode()
        followed = [json.loads(line) for line in output.splitlines()]
        assert len(followed) == 246
        assert followed[-1]["text"] == "Follow-up sample"
        assert len({record["id"] for record in followed}) == len(followed)
    finally:
        if follower.poll() is None:
            follower.kill()
            follower.communicate(timeout=5)
        connection.close()

print("Packaged CLI, full/live JSONL output, exports, synthetic labels, read-only MCP, batching, and file permissions passed.")
