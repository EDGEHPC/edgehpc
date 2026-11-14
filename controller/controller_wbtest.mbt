// SPDX-License-Identifier: GPL-2.0-only

///|
let fixture =
  #|{"schema_version":1,"boot_id":"test-boot","monotonic_seconds":3,"epoch":1760000000}

///|
async test "targeted dispatch can be retried and durable results complete once" {
  let dir = @fs.tmpdir(prefix="edgehpc-control")
  defer @fs.rmdir(dir, recursive=true)
  let task = @model.Task::health_check("job-a", "node-a")
  assert_true(submit(dir, task) is { "status": String("queued"), .. })
  assert_true(pull(dir, "node-b") is None)
  assert_true(pull(dir, "node-a") is Some(t) && t.id == "job-a")
  assert_true(pull(dir, "node-a") is Some(t) && t.id == "job-a")
  assert_true(submit(dir, task) is { "status": String("dispatched"), .. })
  let snapshot = @model.parse_snapshot(fixture)
  let result = task.execute(Some(snapshot), 1760000003000L)
  let delivery = @model.Result(result)
  let ack = receive(dir, "node-a", delivery)
  assert_eq(receive(dir, "node-a", delivery), ack)
  assert_true(pull(dir, "node-a") is None)
  assert_true(submit(dir, task) is { "status": String("completed"), .. })
  assert_true(status(dir, node_id="node-b") is { "tasks": Array([]), .. })
  let conflict = task.execute(None, 1760000003000L)
  let rejected = try {
    ignore(receive(dir, "node-a", @model.Result(conflict)))
    false
  } catch {
    Conflict => true
    _ => false
  }
  assert_true(rejected)
}

///|
async test "alerts are deduplicated across reopen and IDs cannot change payload" {
  let dir = @fs.tmpdir(prefix="edgehpc-receipts")
  defer @fs.rmdir(dir, recursive=true)
  let evidence : @model.Finding = {
    node_id: "node-a",
    rule_id: "hot",
    metric: Temperature("soc"),
    threshold: 80000L,
    observed: 83000L,
    consecutive: 2,
    since_ms: 1000L,
    sample: { boot_id: "test-boot", monotonic_ms: 2000L, },
    occurred_at_ms: 1760000002000L,
  }
  let alert = @model.Alert(@model.Event::from_finding(evidence))
  let first = receive(dir, "node-a", alert)
  assert_eq(receive(dir, "node-a", alert), first)
  assert_true(status(dir) is { "alerts": Array([_]), .. })
  let collision = @model.Alert(
    @model.Event::from_finding({ ..evidence, observed: 84000L, }),
  )
  let rejected = try {
    ignore(receive(dir, "node-a", collision))
    false
  } catch {
    Conflict => true
    _ => false
  }
  assert_true(rejected)
  let cross_node = Some(receive(dir, "node-b", alert)) catch { _ => None }
  assert_true(cross_node is None)
}

///|
async test "only offered tasks accept results" {
  let dir = @fs.tmpdir(prefix="edgehpc-invalid-result")
  defer @fs.rmdir(dir, recursive=true)
  let task = @model.Task::health_check("job-a", "node-a")
  let result = @model.Result(task.execute(None, 1760000003000L))
  let unknown = try {
    ignore(receive(dir, "node-a", result))
    false
  } catch {
    UnknownTask => true
    _ => false
  }
  assert_true(unknown)
  ignore(submit(dir, task))
  let unopened = Some(receive(dir, "node-a", result)) catch { _ => None }
  assert_true(unopened is None)
  ignore(pull(dir, "node-a"))
  ignore(receive(dir, "node-a", result))
  assert_true(submit(dir, task) is { "status": String("failed"), .. })
}
