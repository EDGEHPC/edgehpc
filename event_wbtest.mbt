// SPDX-License-Identifier: GPL-2.0-only

///|
fn hot_event(node_id~ : String = "lab-a", ms~ : Int64 = 3000L) -> Event {
  Event::from_finding({
    node_id,
    rule_id: "hot",
    metric: Temperature("thermal_zone0"),
    threshold: 80000L,
    observed: 81250L,
    consecutive: 3,
    since_ms: 1000L,
    sample: { boot_id: "boot-a", monotonic_ms: ms, },
    occurred_at_ms: 1760000000000L + ms,
  })
}

///|
test "event ID is bound to the node, boot, rule and triggering sample" {
  let event = hot_event()
  assert_eq(event.id, "lab-a:boot-a:hot:3000")
  let restored = parse_event(event.payload().stringify())
  assert_eq(restored.payload(), event.payload())
  assert_true(hot_event(node_id="node-b").id != event.id)
  assert_true(hot_event(ms=4000L).id != event.id)
  let forged = event
    .payload()
    .stringify()
    .replace(old="lab-a:boot-a:hot:3000", new="lab-a:boot-a:hot:3001")
  assert_true((Some(parse_event(forged)) catch { _ => None }) is None)
}

///|
test "an acknowledgement names exactly the accepted event and version" {
  let id = hot_event().id
  verify_acknowledgement(acknowledgement(id).stringify(), id)
  for
    invalid in [
      "{}",
      acknowledgement("different-event").stringify(),
      "{\"schema_version\":2,\"event_id\":\"" + id + "\"}",
      "{\"schema_version\":1,\"event_id\":\"" +
      id +
      "\",\"event_id\":\"" +
      id +
      "\"}",
    ] {
    let accepted = try {
      verify_acknowledgement(invalid, id)
      true
    } catch {
      _ => false
    }
    assert_false(accepted)
  }
}
