# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "export_snapshot", Path(__file__).with_name("export-armhpc-snapshot.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SnapshotExportTest(unittest.TestCase):
    def test_export_does_not_publish_unneeded_fields_or_weaken_source_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory, "source.json")
            output = Path(directory, "health.json")
            snapshot = {
                "schema_version": 1, "boot_id": "boot-test", "monotonic_seconds": 1,
                "epoch": 1700000000, "hostname": "private-host", "state": {"sensitive": True},
                "thermal": {"soc": {"type": "board", "temperature_millicelsius": "81000"}},
                "DATA": {"available_bytes": 9007199254740993, "error": "/private/path"},
            }
            source.write_text(json.dumps(snapshot))
            source.chmod(0o600)
            module.export(source, output, os.getgid())
            self.assertEqual(
                json.loads(output.read_text()),
                {
                    "schema_version": 1, "boot_id": "boot-test", "monotonic_seconds": 1,
                    "epoch": 1700000000, "thermal": {"soc": {"temperature_millicelsius": "81000"}},
                    "DATA": {"available_bytes": 9007199254740993},
                },
            )
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o640)

    def test_invalid_snapshot_cannot_replace_a_previous_export(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory, "source.json")
            output = Path(directory, "health.json")
            output.write_text("previous")
            for payload in ['{"schema_version":2}', '{"schema_version":1,"epoch":NaN}', "{"]:
                source.write_text(payload)
                with self.assertRaises(ValueError):
                    module.export(source, output, os.getgid())
                self.assertEqual(output.read_text(), "previous")
                self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["health.json", "source.json"])


if __name__ == "__main__":
    unittest.main()
