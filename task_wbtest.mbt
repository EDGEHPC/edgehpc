// SPDX-License-Identifier: GPL-2.0-only

///|
test "only the implemented health check is a valid remotely assigned task" {
  let task = Task::health_check("sample-1", "lab-a")
  assert_eq(parse_task(task.payload().stringify()).payload(), task.payload())
  for
    body in [
      (
        #|{"schema_version":1,"task_id":"sample-1","node_id":"lab-a","kind":"command"}
      ),
      (
        #|{"schema_version":1,"task_id":"../sample","node_id":"lab-a","kind":"health_check"}
      ),
      (
        #|{"schema_version":1,"task_id":"sample-1","node_id":"lab-a","kind":"health_check","argv":["sh"]}
      ),
    ] {
    assert_true((Some(parse_task(body)) catch { _ => None }) is None)
  }
}

///|
test "a dispatched check evaluates node-local policy without changing alert streaks" {
  let policy = parse_policy(policy_json(thermal_rule + "," + disk_rule))
  let task = Task::health_check("site-visit", "lab-a")
  let sample = reading(1L, Some(81000L))
  let result = task.execute(Some(sample), sample.epoch_ms, policy~)
  assert_true(
    parse_task_result(result.payload().stringify()).checks
    is [
      {
        "rule_id": String("hot"),
        "status": String("out_of_range"),
        "observed": String("81000"),
        ..
      },
      {
        "rule_id": String("disk"),
        "status": String("unknown"),
        "observed": Null,
        ..
      },
    ],
  )
  let altered = result
    .payload()
    .stringify()
    .replace(old="out_of_range", new="within_range")
  assert_true((Some(parse_task_result(altered)) catch { _ => None }) is None)
  let (_, sustained) = Monitor().advance(policy, sample)
  assert_true(sustained.is_empty())
}

///|
test "edge task results distinguish successful inspection from missing data" {
  let task = Task::health_check("sample-1", "lab-a")
  let sample = reading(3L, Some(82222L), bytes=Some(9007199254740993L))
  let succeeded = task.execute(Some(sample), sample.epoch_ms)
  let failed = task.execute(None, sample.epoch_ms)
  let completed = parse_task_result(succeeded.payload().stringify())
  assert_true(completed.successful)
  assert_eq(completed.delivery_id(), failed.delivery_id())
  assert_eq(completed.readings, {
    "temperatures_millicelsius": { "thermal_zone0": 82222 },
    "data_available_bytes": "9007199254740993",
  })
  assert_false(parse_task_result(failed.payload().stringify()).successful)
  let forged = succeeded
    .payload()
    .stringify()
    .replace(old="task:lab-a:sample-1", new="task:lab-b:sample-1")
  assert_true((Some(parse_task_result(forged)) catch { _ => None }) is None)
}
