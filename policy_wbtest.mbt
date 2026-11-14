// SPDX-License-Identifier: GPL-2.0-only

///|
fn policy_json(
  rules : String,
  capacity~ : Int32 = 10,
  node_id~ : String = "lab-a",
) -> String {
  "{\"schema_version\":1,\"node_id\":\"" +
  node_id +
  "\",\"queue_capacity\":\{capacity},\"rules\":[" +
  rules +
  "]}"
}

///|
let thermal_rule =
  #|{"id":"hot","metric":"temperature_millicelsius","sensor":"thermal_zone0","threshold":80000,"consecutive":3,"max_gap_seconds":120}

///|
let disk_rule =
  #|{"id":"disk","metric":"data_available_bytes","threshold":9007199254740993,"consecutive":2,"max_gap_seconds":90}

///|
test "decode temperature and disk policies with byte-exact limits" {
  let policy = parse_policy(policy_json(thermal_rule + "," + disk_rule))
  assert_eq(policy.node_id, "lab-a")
  assert_eq(policy.queue_capacity, 10)
  assert_true(policy.rules[0].metric == Temperature("thermal_zone0"))
  assert_true(policy.rules[1].metric == DataAvailable)
  assert_eq(policy.rules[1].threshold, 9007199254740993L)
  assert_eq(policy.rules[0].max_gap_ms, 120000L)
}

///|
test "reject rule and capacity errors before operating on a queue" {
  let misspelled =
    #|{"id":"hot","metric":"temperature_millicelsius","sensor":"thermal_zone0","threshold":80000,"consecutive":3,"max_gap_second":120}
  let disabled =
    #|{"id":"disk","metric":"data_available_bytes","threshold":-1,"consecutive":1,"max_gap_seconds":120}
  for
    source in [
      policy_json(thermal_rule + "," + disk_rule, capacity=1),
      policy_json(thermal_rule + "," + thermal_rule),
      policy_json(thermal_rule, node_id="../lab"),
      policy_json(thermal_rule, capacity=1025),
      policy_json(misspelled),
      policy_json(disabled),
      policy_json(""),
    ] {
    let parsed = Some(parse_policy(source)) catch { _ => None }
    assert_true(parsed is None)
  }
}
