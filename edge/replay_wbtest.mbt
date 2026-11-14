// SPDX-License-Identifier: GPL-2.0-only

///|
async test "transport failure retains a durable record; replay resumes from its head" {
  let dir = @fs.tmpdir(prefix="edgehpc-replay")
  defer @fs.rmdir(dir, recursive=true)
  let policy = @model.parse_policy(policy_source)
  ignore(tick(dir, policy, Some(sample(1L, 81000L)), 0L))
  ignore(tick(dir, policy, Some(sample(2L, 82000L)), 0L))
  let first = replay(dir, "node-a", _ => raise Failure("offline"))
  assert_true(first.deferred)
  assert_eq(first.acknowledged, 0)
  let persisted = []
  let second = replay(dir, "node-a", record => persisted.push(record.id()))
  assert_false(second.deferred)
  assert_eq(second.acknowledged, 1)
  assert_eq(persisted, ["node-a:boot-a:hot:2000"])
  assert_eq(
    replay(dir, "node-a", _ => fail("acknowledged record resent")).acknowledged,
    0,
  )
}

///|
async test "a network tick does not execute work; a later offline local tick can finish it" {
  let dir = @fs.tmpdir(prefix="edgehpc-pull")
  defer @fs.rmdir(dir, recursive=true)
  let policy = @model.parse_policy(policy_source)
  let task = @model.Task::health_check("request-1", "node-a")
  let online = synchronize(dir, "node-a", () => Some(task), _ => {
    fail("premature delivery")
  })
  assert_true(online.task_accepted)
  assert_true(
    status(dir, "node-a") is { "inbox": Object(_), "pending_result": Null, .. },
  )
  let local_result = tick(dir, policy, Some(sample(1L, 81000L)), 1760000001000L)
  assert_true(local_result.task_completed)
  let offline = synchronize(
    dir,
    "node-a",
    () => fail("pulled while result pending"),
    _ => raise Failure("offline"),
  )
  assert_true(offline.transport_deferred)
  assert_true(
    status(dir, "node-a") is { "inbox": Null, "pending_result": Object(_), .. },
  )
  let replayed = synchronize(
    dir,
    "node-a",
    () => fail("pulled while result pending"),
    record => assert_eq(record.id(), "task:node-a:request-1"),
  )
  assert_eq(replayed.acknowledged, 1)
  assert_false(replayed.transport_deferred)
}
