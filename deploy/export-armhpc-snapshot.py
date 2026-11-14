#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Export only the ARMHPC fields needed by the unprivileged EdgeHPC node."""

import grp
import json
import os
from pathlib import Path
import sys
import tempfile


MAX_SNAPSHOT_BYTES = 1024 * 1024
FIELDS = ("schema_version", "boot_id", "monotonic_seconds", "epoch")


def export(source: Path, destination: Path, gid: int) -> None:
    with source.open("rb") as stream:
        data = stream.read(MAX_SNAPSHOT_BYTES + 1)
    if len(data) > MAX_SNAPSHOT_BYTES:
        raise ValueError("health snapshot is too large")
    sample = json.loads(data)
    if type(sample) is not dict or type(sample.get("schema_version")) is not int or sample["schema_version"] != 1:
        raise ValueError("unsupported ARMHPC snapshot")
    payload = {key: sample[key] for key in FIELDS if key in sample}
    thermal = sample.get("thermal")
    if isinstance(thermal, dict):
        payload["thermal"] = {
            name: {"temperature_millicelsius": zone["temperature_millicelsius"]}
            for name, zone in thermal.items()
            if isinstance(zone, dict) and "temperature_millicelsius" in zone
        }
    disk = sample.get("DATA")
    if isinstance(disk, dict) and "available_bytes" in disk:
        payload["DATA"] = {"available_bytes": disk["available_bytes"]}

    # tmpfiles creates the destination directory; the service account cannot
    # change names inside it. Never loosen the original file's permissions.
    fd, temp = tempfile.mkstemp(prefix=".health.", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchown(stream.fileno(), -1, gid)
            os.fchmod(stream.fileno(), 0o640)
            json.dump(payload, stream, separators=(",", ":"), allow_nan=False)
            stream.write("\n")
        os.replace(temp, destination)
    finally:
        Path(temp).unlink(missing_ok=True)


def main() -> int:
    try:
        export(
            Path("/run/armhpc/health.json"),
            Path("/run/edgehpc-input/health.json"),
            grp.getgrnam("edgehpc").gr_gid,
        )
    except (OSError, ValueError, KeyError) as error:
        # The optional export must not make the original health collector fail.
        print(f"edgehpc snapshot export: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
