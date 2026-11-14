// SPDX-License-Identifier: GPL-2.0-only

///|
fn reading(
  seconds : Int64,
  temperature : Int64?,
  boot~ : String = "boot-a",
  bytes~ : Int64? = None,
) -> Snapshot {
  let temperatures : Map[String, Int64] = Map([])
  if temperature is Some(t) {
    temperatures["thermal_zone0"] = t
  }
  {
    boot_id: boot,
    monotonic_ms: seconds * 1000L,
    epoch_ms: 1760000000000L + seconds * 1000L,
    temperatures,
    data_available_bytes: bytes,
  }
}

///|
test "a sustained condition emits once with evidence and rearms on normal" {
  let policy = parse_policy(policy_json(thermal_rule))
  let mut state = Monitor()
  for seconds in [10L, 20L, 30L, 40L, 50L, 60L, 70L, 80L] {
    let value = if seconds == 50L { 79999L } else { 80000L }
    let (next, findings) = state.advance(policy, reading(seconds, Some(value)))
    state = next
    if seconds == 30L || seconds == 80L {
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].since_ms, (seconds - 20L) * 1000L)
      assert_eq(findings[0].sample.monotonic_ms, seconds * 1000L)
      assert_eq(findings[0].observed, 80000L)
      assert_eq(findings[0].threshold, 80000L)
    } else {
      assert_true(findings.is_empty())
    }
  }
}

///|
test "duplicate, stale, gap, missing, and reboot samples do not manufacture continuity" {
  let policy = parse_policy(policy_json(thermal_rule))
  let mut state = Monitor()
  for
    input in [
      reading(1L, Some(81000L)),
      reading(1L, Some(81000L)),
      reading(0L, Some(81000L)),
      reading(123L, Some(81000L)),
      reading(180L, None),
      reading(240L, Some(81000L)),
      reading(300L, Some(81000L)),
      reading(1L, Some(81000L), boot="boot-b"),
      reading(60L, Some(81000L), boot="boot-b"),
    ] {
    let (next, findings) = state.advance(policy, input)
    assert_true(findings.is_empty())
    state = next
  }
  let (_, findings) = state.advance(
    policy,
    reading(120L, Some(81000L), boot="boot-b"),
  )
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].since_ms, 1000L)
}

///|
test "disk boundary and rule edits use the configured policy, not a former streak" {
  let policy = parse_policy(policy_json(disk_rule))
  let threshold = 9007199254740993L
  let (state, first) = Monitor().advance(
    policy,
    reading(1L, None, bytes=Some(threshold)),
  )
  assert_true(first.is_empty())
  let (state, second) = state.advance(
    policy,
    reading(2L, None, bytes=Some(threshold - 1L)),
  )
  assert_true(second.is_empty())
  let edited = parse_policy(
    policy_json(
      disk_rule.replace(old="9007199254740993", new="9007199254740994"),
    ),
  )
  let (state, third) = state.advance(
    edited,
    reading(3L, None, bytes=Some(threshold - 1L)),
  )
  assert_true(third.is_empty())
  let (_, fourth) = state.advance(
    edited,
    reading(4L, None, bytes=Some(threshold - 1L)),
  )
  assert_eq(fourth.length(), 1)
}

///|
test "missing readings and gaps alone do not rearm an emitted alarm" {
  let policy = parse_policy(policy_json(thermal_rule))
  let mut state = Monitor()
  for seconds in [1L, 2L, 3L, 4L, 240L, 241L, 242L] {
    let value = if seconds == 4L { None } else { Some(81000L) }
    let (next, findings) = state.advance(policy, reading(seconds, value))
    assert_eq(findings.length(), if seconds == 3L { 1 } else { 0 })
    state = next
  }
}
