#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Process-level regression checks with a local controller and synthetic sensors."""

import contextlib
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time


TOKEN = secrets.token_hex(32)
NODE_ID = "lab-a"
BOOT_ID = "fixture-boot"


def write(path, value):
    data = value if isinstance(value, str) else json.dumps(value)
    staging = path.with_name(f".{path.name}.new")
    fd = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(data)
    staging.replace(path)


def send(url_port, method, path, *, token=None, payload=None):
    conn = HTTPConnection("127.0.0.1", url_port, timeout=1)
    try:
        headers = {"Connection": "close"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if payload is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=None if payload is None else json.dumps(payload), headers=headers)
        response = conn.getresponse()
        contents = response.read()
        return response.status, json.loads(contents) if contents else None
    finally:
        conn.close()


def wait_for(predicate, description, timeout=16):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if value := predicate():
                return value
        except (ConnectionError, TimeoutError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {description}")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Lab:
    def __init__(self, directory, cli):
        self.directory = directory
        self.cli = cli
        self.state = directory / "edge"
        self.controller = directory / "control"
        self.policy = directory / "policy.json"
        self.snapshot = directory / "health.json"
        self.credentials = directory / "controller-credentials.json"
        self.token = directory / "node-token"
        self.port = free_port()
        self.origin = f"http://127.0.0.1:{self.port}"
        self.controller_logs = directory / "controller.log"
        self.node_logs = directory / "node.log"
        write(self.credentials, {"schema_version": 1, "nodes": {NODE_ID: TOKEN}})
        write(self.token, TOKEN + "\n")
        write(self.policy, {
            "schema_version": 1,
            "node_id": NODE_ID,
            "queue_capacity": 4,
            "rules": [
                {"id": "soc-hot", "metric": "temperature_millicelsius", "sensor": "soc",
                 "threshold": 80000, "consecutive": 3, "max_gap_seconds": 120},
                {"id": "data-low", "metric": "data_available_bytes",
                 "threshold": 100, "consecutive": 2, "max_gap_seconds": 120},
            ],
        })

    def run(self, *args, env=None):
        proc = subprocess.run(
            [*self.cli, *map(str, args)], capture_output=True, text=True,
            timeout=8, env=env,
        )
        assert proc.returncode == 0, (args, proc.returncode, proc.stdout, proc.stderr)
        return json.loads(proc.stdout)

    @contextlib.contextmanager
    def process(self, log, *args):
        with log.open("a", encoding="utf-8") as stream:
            proc = subprocess.Popen([*self.cli, *map(str, args)], stdout=stream, stderr=stream)
            try:
                yield proc
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=4)

    @contextlib.contextmanager
    def serve(self):
        with self.process(
            self.controller_logs, "controller", "serve", self.controller, self.credentials,
            f"127.0.0.1:{self.port}",
        ) as proc:
            wait_for(lambda: send(self.port, "GET", "/healthz")[0] == 200, "controller to listen")
            assert proc.poll() is None
            yield

    def sync(self, origin=None, *, env=None):
        return self.run("node", "sync", self.state, self.policy, origin or self.origin, self.token, env=env)

    def node_status(self):
        return self.run("node", "status", self.state, NODE_ID)

    def control_status(self):
        return self.run("controller", "status", self.controller)

    def set_sample(self, second, *, hot=True, low=True):
        write(self.snapshot, {
            "schema_version": 1, "boot_id": BOOT_ID, "monotonic_seconds": second,
            "epoch": time.time(), "hostname": "must-not-be-sent",
            "thermal": {"soc": {"temperature_millicelsius": "81000" if hot else "42000"}},
            "DATA": {"available_bytes": 10 if low else 500},
        })

    def sample(self, second, **kwargs):
        self.set_sample(second, **kwargs)
        return self.run("node", "sample", self.state, self.policy, self.snapshot)

    def dump_logs(self):
        for path in (self.controller_logs, self.node_logs):
            if path.exists():
                print(f"--- {path.name} ---\n{path.read_text()}", file=sys.stderr)


@contextlib.contextmanager
def bad_ack():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            # The client streams its JSON body as HTTP chunks. Read through EOF
            # of that message before returning a valid but mismatched ACK.
            assert self.headers.get("Transfer-Encoding", "").lower() == "chunked"
            while size := int(self.rfile.readline().strip(), 16):
                self.rfile.read(size + 2)
            self.rfile.readline()
            body = b'{"schema_version":1,"event_id":"wrong-id"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with http_server(Handler) as server:
        yield f"http://127.0.0.1:{server.server_port}"


@contextlib.contextmanager
def http_server(handler, context=None):
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        if context is not None:
            server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join(timeout=4)


def restart_and_replay(lab):
    assert lab.run("controller", "submit", lab.controller, NODE_ID, "visit-1", "health-check")["status"] == "queued"
    with lab.serve():
        task_path = f"/v1/nodes/{NODE_ID}/tasks/next"
        assert send(lab.port, "GET", task_path)[0] == 401
        assert send(lab.port, "GET", "/v1/nodes/other/tasks/next", token=TOKEN)[0] == 401
        assert lab.sync()["task_accepted"]
        assert lab.node_status()["inbox"]["task_id"] == "visit-1"
        assert lab.control_status()["tasks"][0]["status"] == "dispatched"

    before_work = lab.sync()
    assert before_work["acknowledged"] == 0 and not before_work["task_accepted"]
    assert lab.sample(1, hot=False, low=False)["task_completed"]
    assert lab.sync()["transport_deferred"]
    assert lab.sample(60)["alerts"] == 0
    assert lab.sample(60)["alerts"] == 0  # Rereading the same snapshot is not another sample.
    assert lab.sample(120)["alerts"] == 1  # Two disk samples.
    assert lab.sample(180)["alerts"] == 1  # Three temperature samples.
    assert lab.sample(240)["alerts"] == 0  # Already latched.

    before = lab.node_status()
    assert before["pending_result"]["task_id"] == "visit-1"
    assert [entry["rule_id"] for entry in before["pending_alerts"]] == ["data-low", "soc-hot"]
    with bad_ack() as origin:
        outcome = lab.sync(origin)
        assert outcome["transport_deferred"] and outcome["acknowledged"] == 0
    assert lab.node_status() == before

    with lab.serve():
        # The controller writes the receipt; the node process never sees the ACK.
        # A replay must finish normally without creating another controller record.
        path = f"/v1/nodes/{NODE_ID}/deliveries"
        for entry in [before["pending_result"], before["pending_alerts"][0]]:
            status, response = send(lab.port, "POST", path, token=TOKEN, payload=entry)
            assert status == 200 and response["event_id"] == entry["event_id"]
        assert lab.sync()["acknowledged"] == 3
        assert lab.sync()["acknowledged"] == 0
        local = lab.node_status()
        assert local["pending_result"] is None and local["pending_alerts"] == []
        assert [entry["rule_id"] for entry in local["recent_alerts"]] == ["data-low", "soc-hot"]

    final = lab.control_status()
    assert len(final["tasks"]) == 1 and final["tasks"][0]["status"] == "completed"
    assert final["tasks"][0]["result"]["readings"] == {
        "temperatures_millicelsius": {"soc": 42000}, "data_available_bytes": "500",
    }
    assert {
        entry["rule_id"]: entry["status"]
        for entry in final["tasks"][0]["result"]["checks"]
    } == {"soc-hot": "within_range", "data-low": "within_range"}
    assert len({entry["event_id"] for entry in final["alerts"]}) == len(final["alerts"]) == 2
    assert [entry["observed"] for entry in final["alerts"]] == ["10", "81000"]
    print("PASS: targeted dispatch, offline execution, sustained evidence, restart, bad ACK and deduplicated replay")


def continuous_worker(lab):
    lab.run("controller", "submit", lab.controller, NODE_ID, "daemon-1", "health-check")
    lab.set_sample(1, hot=False, low=False)
    with lab.process(
        lab.node_logs, "node", "run", lab.state, lab.policy, lab.snapshot, lab.origin, lab.token,
    ) as proc:
        wait_for(
            lambda: bool(lab.node_status()["last_sample"]),
            "the node to read a fresh snapshot without a controller",
        )
        assert proc.poll() is None
        with lab.serve():
            wait_for(
                lambda: lab.control_status()["tasks"][0]["status"] == "completed",
                "automatic task pull, execution and reporting",
            )
        for second in (60, 120, 180):
            lab.set_sample(second)
            wait_for(
                lambda: lab.node_status()["last_sample"]["monotonic_ms"] == str(second * 1000),
                f"sample {second} processed while controller is stopped",
            )
        assert len(lab.node_status()["pending_alerts"]) == 2
        with lab.serve():
            wait_for(
                lambda: len(lab.control_status()["alerts"]) == 2 and not lab.node_status()["pending_alerts"],
                "automatic replay after the controller returns",
            )
        assert proc.poll() is None
    print("PASS: independent sampling and automatic retry while the controller is stopped and restarted")


def verified_https(lab):
    cert = lab.directory / "local-test-ca.pem"
    key = lab.directory / "local-test-key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-noenc", "-days", "1",
        "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
        "-keyout", key, "-out", cert,
    ], check=True, capture_output=True, timeout=10)

    class Proxy(BaseHTTPRequestHandler):
        def do_GET(self):
            status, record = send(
                lab.port, "GET", self.path,
                token=self.headers.get("Authorization", "").removeprefix("Bearer "),
            )
            data = json.dumps(record).encode() if record is not None else b""
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    # Linux's native MoonBit TLS backend uses the system roots via OpenSSL.
    # Scope the added root to the child process; don't change the host trust store.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    trust = {**os.environ, "SSL_CERT_FILE": str(cert)}
    lab.run("controller", "submit", lab.controller, NODE_ID, "tls-1", "health-check")
    with lab.serve(), http_server(Proxy, context) as server:
        origin = f"https://127.0.0.1:{server.server_port}"
        assert lab.sync(origin)["transport_deferred"]  # Certificate is untrusted.
        assert lab.sync(f"https://localhost:{server.server_port}", env=trust)["transport_deferred"]
        assert lab.node_status()["inbox"] is None  # A matching root alone is not enough.
        assert lab.sync(origin, env=trust)["task_accepted"]
        assert lab.node_status()["inbox"]["task_id"] == "tls-1"
    print("PASS: node accepts a trusted HTTPS controller and rejects unknown roots and mismatched hosts")


def main():
    arguments = sys.argv[1:]
    tls = bool(arguments and arguments[0] == "--native-tls")
    if tls:
        arguments = arguments[1:]
    if not arguments:
        raise SystemExit("usage: python3 tests/e2e.py EDGEHPC_EXECUTABLE [EXECUTABLE_PREFIX_ARGS...]")
    checks = [restart_and_replay, continuous_worker]
    if tls:
        checks.append(verified_https)
    for regression in checks:
        with tempfile.TemporaryDirectory(prefix="edgehpc-e2e-") as path:
            lab = Lab(Path(path), arguments)
            try:
                regression(lab)
            except Exception:
                lab.dump_logs()
                raise


if __name__ == "__main__":
    main()
