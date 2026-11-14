// SPDX-License-Identifier: GPL-2.0-only

///|
test "production sampling rejects stale and far-future snapshots" {
  let snapshot = @health.parse_snapshot(
    (
      #|{"schema_version":1,"boot_id":"a","monotonic_seconds":1,"epoch":1000}
    ),
  )
  assert_true(sample_is_fresh(snapshot, 1005000L))
  assert_true(sample_is_fresh(snapshot, 995000L))
  assert_false(sample_is_fresh(snapshot, 994999L))
  assert_false(sample_is_fresh(snapshot, 1180001L))
}
