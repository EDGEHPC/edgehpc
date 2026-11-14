# EdgeHPC

[简体中文](README.zh-CN.md)

EdgeHPC runs health-check tasks on ARM Linux nodes with intermittent connectivity. The controller queues work for a specific node. The node pulls the task, saves it locally, reads its own health snapshot, and applies its own policy. It can finish an accepted task while disconnected. The same node raises sustained temperature and disk-space alerts without an uplink.

## Quick start

Use Linux, MoonBit (`moonc v0.10.20+65efd5b93` in CI), a C compiler and Python 3. This demo runs on one machine, with synthetic readings and a random lab token.

```sh
moon build --target native --release cmd/edgehpc
BIN="$PWD/_build/native/release/build/cmd/edgehpc/edgehpc.exe"
LAB=$(mktemp -d)
umask 077
python3 - "$LAB" <<'PY'
import json, secrets, sys, time
from pathlib import Path

root = Path(sys.argv[1])
token = secrets.token_hex(32)
(root / "node-token").write_text(token + "\n")
(root / "credentials.json").write_text(json.dumps(
    {"schema_version": 1, "nodes": {"lab-a": token}}
))
(root / "health.json").write_text(json.dumps({
    "schema_version": 1, "boot_id": "demo-boot", "monotonic_seconds": 1,
    "epoch": time.time(),
    "thermal": {"thermal_zone0": {"temperature_millicelsius": "42000"}},
    "DATA": {"available_bytes": 2147483648},
}))
PY

"$BIN" controller submit "$LAB/controller" lab-a visit-1 health-check
"$BIN" controller serve "$LAB/controller" "$LAB/credentials.json" 127.0.0.1:8420 &
server=$!
```

After the controller prints `listening`, pull the task and stop the controller. The node completes the task without it.

```sh
"$BIN" node sync "$LAB/node" examples/policy.json http://127.0.0.1:8420 "$LAB/node-token"
kill "$server"
wait "$server" || true

"$BIN" node sample "$LAB/node" examples/policy.json "$LAB/health.json"
"$BIN" node status "$LAB/node" lab-a
# pending_result contains readings and rule verdicts.

"$BIN" controller serve "$LAB/controller" "$LAB/credentials.json" 127.0.0.1:8420 &
server=$!
# Wait for "listening" before syncing.
"$BIN" node sync "$LAB/node" examples/policy.json http://127.0.0.1:8420 "$LAB/node-token"
"$BIN" controller status "$LAB/controller" lab-a
kill "$server"
wait "$server" || true
```

For continuous operation, use `node run STATE_DIR POLICY SNAPSHOT ORIGIN TOKEN_FILE`. It runs local sampling independently of network requests. Only `health-check` is supported; the controller cannot send shell commands. See the [ARMHPC deployment guide](deploy/README.md) for systemd, collector permissions, and HTTPS across hosts.

## Behaviour and limits

- The inspection reports instantaneous verdicts, with missing values marked unknown. Sustained alerts use separate rules with a threshold, a consecutive-sample count and a maximum gap. Repeated snapshots do not count twice.
- The node persists accepted tasks, results and unconfirmed alerts. An alert FIFO at capacity keeps existing records and defers new findings; a separate slot is reserved for one task result.
- The controller stores each delivery before replying. Replays of the same ID and payload do not create another record. The node removes a result or alert from the pending queue only after a matching acknowledgement.
- Each node uses its own credential. Remote nodes connect through a trusted HTTPS reverse proxy; the controller's HTTP listener is loopback-only. Submit and query tasks through the local CLI.
- Controller storage is bounded at 512 task IDs and 2,048 alert IDs; there is no automatic history pruning. Use private persistent state directories with room for atomic replacement.

Firmware and recovery remain in [armbian-hpc](https://github.com/EDGEHPC/armbian-hpc); signed updates remain in [armhpc-ota](https://github.com/EDGEHPC/armhpc-ota). The systemd integration is supplied, but no board image or physical-board test result has been published.

## Verify

```sh
moon fmt --check
moon check -d
moon test
moon test --target native
moon build --target native --release cmd/edgehpc
python3 tests/e2e.py --native-tls "$PWD/_build/native/release/build/cmd/edgehpc/edgehpc.exe"
python3 deploy/test_export.py
```

The end-to-end test uses loopback networking and synthetic snapshots. It stops and restarts the controller, checks offline task execution and automatic replay, and simulates a missing or incorrect acknowledgement. The native HTTPS check requires OpenSSL.

The source is licensed under [GPL-2.0-only](LICENSE). Use synthetic or redacted data in reports. See the [contribution guide](https://github.com/EDGEHPC/.github/blob/main/CONTRIBUTING.md).
