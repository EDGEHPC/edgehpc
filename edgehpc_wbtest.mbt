// SPDX-License-Identifier: GPL-2.0-only

///|
test "read health values without copying host metadata" {
  let report = inspect_snapshot(
    (
      #|{"schema_version":1,"hostname":"fixture","thermal":{"thermal_zone0":{"type":"soc","temperature_millicelsius":"42000"}},"DATA":{"available_bytes":2147483648}}
    ),
  )
  assert_eq(report, {
    "temperatures_millicelsius": { "thermal_zone0": 42000 },
    "data_available_bytes": "2147483648",
  })
}

///|
test "missing and unreadable measurements stay unknown" {
  let report = inspect_snapshot(
    (
      #|{"schema_version":1,"thermal":{"missing":{"temperature_millicelsius":null},"invalid":{"temperature_millicelsius":"not-a-reading"},"valid":{"temperature_millicelsius":"-1000"}},"DATA":{"error":"not mounted"}}
    ),
  )
  assert_eq(report, {
    "temperatures_millicelsius": { "valid": -1000 },
    "data_available_bytes": null,
  })
}

///|
test "large integers are not rounded" {
  let report = inspect_snapshot(
    (
      #|{"schema_version":1,"DATA":{"available_bytes":9007199254740993}}
    ),
  )
  assert_eq(report, {
    "temperatures_millicelsius": {},
    "data_available_bytes": "9007199254740993",
  })
}

///|
test "invalid storage counts are not reported" {
  for raw in ["-1", "1.5", "9223372036854775808"] {
    let report = inspect_snapshot(
      "{\"schema_version\":1,\"DATA\":{\"available_bytes\":" + raw + "}}",
    )
    assert_eq(report, {
      "temperatures_millicelsius": {},
      "data_available_bytes": null,
    })
  }
}

///|
test "unsupported and ambiguous input is rejected" {
  for
    raw in [
      "{}", "[]", "{\"schema_version\":2}", "{\"schema_version\":1,\"schema_version\":1}",
      "{\"schema_version\":1",
    ] {
    let parsed = Some(inspect_snapshot(raw)) catch { _ => None }
    assert_true(parsed is None)
  }
}
