// SPDX-License-Identifier: GPL-2.0-only

///|
let policy_source =
  #|{"schema_version":1,"node_id":"node-a","queue_capacity":1,"rules":[{"id":"hot","metric":"temperature_millicelsius","sensor":"soc","threshold":80000,"consecutive":2,"max_gap_seconds":10}]}

///|
fn sample(number : Int64, temp : Int64) -> @model.Snapshot {
  {
    boot_id: "boot-a",
    monotonic_ms: number * 1000L,
    epoch_ms: 1760000000000L + number * 1000L,
    temperatures: Map([("soc", temp)]),
    data_available_bytes: None,
  }
}

///|
async test "streak, alert and acknowledged history survive closing and reopening state" {
  let dir = @fs.tmpdir(prefix="edgehpc-outbox")
  defer @fs.rmdir(dir, recursive=true)
  let policy = @model.parse_policy(policy_source)
  assert_eq(tick(dir, policy, Some(sample(1L, 81000L)), 0L).alerts, 0)
  assert_eq(tick(dir, policy, Some(sample(2L, 82000L)), 0L).alerts, 1)
  let first = next_delivery(dir, "node-a")
  guard first is Some(Alert(event)) else { fail("no durable alert") }
  assert_true(event.id == "node-a:boot-a:hot:2000")
  assert_false(confirm(dir, "node-a", "wrong-id"))
  assert_true(confirm(dir, "node-a", event.id))
  assert_true(next_delivery(dir, "node-a") is None)
  assert_true(status(dir, "node-a") is { "recent_alerts": Array([_]), .. })
}

///|
async test "a full alert spool preserves unacknowledged alerts and reserves a result slot" {
  let dir = @fs.tmpdir(prefix="edgehpc-capacity")
  defer @fs.rmdir(dir, recursive=true)
  let policy = @model.parse_policy(policy_source)
  for (n, value) in [(1L, 81000L), (2L, 81000L), (3L, 70000L), (4L, 81000L)] {
    ignore(tick(dir, policy, Some(sample(n, value)), 0L))
  }
  let task = @model.Task::health_check("request-1", "node-a")
  assert_true(accept(dir, "node-a", task))
  assert_false(accept(dir, "node-a", task))
  let outcome = tick(dir, policy, Some(sample(5L, 81000L)), 1760000005000L)
  assert_true(outcome.queue_full && outcome.task_completed)
  guard next_delivery(dir, "node-a") is Some(Result(result)) else {
    fail("no durable result")
  }
  assert_false(can_receive(dir, "node-a"))
  assert_true(confirm(dir, "node-a", result.delivery_id()))
  guard next_delivery(dir, "node-a") is Some(Alert(alert)) else {
    fail("previous alert was lost")
  }
  assert_eq(alert.id, "node-a:boot-a:hot:2000")
  assert_true(confirm(dir, "node-a", alert.id))
  assert_eq(tick(dir, policy, Some(sample(5L, 81000L)), 0L).alerts, 1)
}

///|
async test "wrong-node tasks and corrupt state are rejected without replacement" {
  let dir = @fs.tmpdir(prefix="edgehpc-corrupt")
  defer @fs.rmdir(dir, recursive=true)
  let task = @model.Task::health_check("request-1", "different-node")
  let accepted = Some(accept(dir, "node-a", task)) catch { _ => None }
  assert_true(accepted is None)
  @fs.write_text(dir + "/node.json", "{", create_mode=CreateNew)
  let result = Some(
    accept(dir, "node-a", @model.Task::health_check("request-1", "node-a")),
  ) catch {
    _ => None
  }
  assert_true(result is None)
  assert_eq(@fs.read_text(dir + "/node.json"), "{")
}
