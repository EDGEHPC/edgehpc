// SPDX-License-Identifier: GPL-2.0-only

///|
#derive(Eq, @json.ToJson, @json.FromJson)
pub(all) struct Cursor {
  boot_id : String
  monotonic_ms : Int64
}

///|
pub extend Cursor with Eq::{not_equal, equal}

///|
pub extend Cursor with @json.ToJson::{to_json}

///|
pub extend Cursor with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
pub struct RuleProgress {
  policy_key : String
  count : Int32
  since_ms : Int64
  latched : Bool
}

///|
pub extend RuleProgress with @json.ToJson::{to_json}

///|
pub extend RuleProgress with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
pub struct Monitor {
  cursor : Cursor?
  progress : Map[String, RuleProgress]
}

///|
pub extend Monitor with @json.ToJson::{to_json}

///|
pub extend Monitor with @json.FromJson::{from_json}

///|
/// Evidence from the first through the triggering sample, all from one boot.
pub(all) struct Finding {
  node_id : String
  rule_id : String
  metric : Metric
  threshold : Int64
  observed : Int64
  consecutive : Int32
  since_ms : Int64
  sample : Cursor
  occurred_at_ms : Int64
}

///|
pub fn Monitor::Monitor() -> Monitor {
  { cursor: None, progress: Map([]), }
}

///|
fn Rule::key(self : Rule) -> String {
  let metric = match self.metric {
    DataAvailable => "data"
    Temperature(sensor) => "temp:\{sensor}"
  }
  "\{metric}:\{self.threshold}:\{self.consecutive}:\{self.max_gap_ms}"
}

///|
fn Rule::reading(self : Rule, sample : Snapshot) -> Int64? {
  match self.metric {
    Temperature(sensor) => sample.temperatures.get(sensor)
    DataAvailable => sample.data_available_bytes
  }
}

///|
fn Rule::violates(self : Rule, value : Int64) -> Bool {
  match self.metric {
    Temperature(_) => value >= self.threshold
    DataAvailable => value < self.threshold
  }
}

///|
fn RuleProgress::fresh(key : String) -> RuleProgress {
  { policy_key: key, count: 0, since_ms: 0L, latched: false, }
}

///|
/// Count distinct consecutive violations. Normal readings rearm a fired rule.
/// Unknown readings or gaps break a streak; a gap alone does not rearm an alarm.
pub fn Monitor::advance(
  self : Monitor,
  policy : Policy,
  sample : Snapshot,
) -> (Monitor, Array[Finding]) {
  let same_boot = self.cursor is Some(prior) && prior.boot_id == sample.boot_id
  let previous_ms = self.cursor.map(fn(p) { p.monotonic_ms }).unwrap_or(0L)
  if same_boot && sample.monotonic_ms <= previous_ms {
    return (self, [])
  }
  let cursor = Cursor::{
    boot_id: sample.boot_id,
    monotonic_ms: sample.monotonic_ms,
  }
  let findings : Array[Finding] = []
  let progress : Map[String, RuleProgress] = Map([])
  for rule in policy.rules {
    let key = rule.key()
    let prior = if same_boot &&
      self.progress.get(rule.id) is Some(old) &&
      old.policy_key == key {
      old
    } else {
      RuleProgress::fresh(key)
    }
    let next = match rule.reading(sample) {
      None => { ..prior, count: 0, since_ms: 0L, }
      Some(value) if !rule.violates(value) => RuleProgress::fresh(key)
      Some(_) if prior.latched => prior
      Some(value) => {
        let joined = prior.count > 0 &&
          sample.monotonic_ms - previous_ms <= rule.max_gap_ms
        let count = if joined { prior.count + 1 } else { 1 }
        let since_ms = if joined { prior.since_ms } else { sample.monotonic_ms }
        let latched = count == rule.consecutive
        if latched {
          findings.push({
            node_id: policy.node_id,
            rule_id: rule.id,
            metric: rule.metric,
            threshold: rule.threshold,
            observed: value,
            consecutive: count,
            since_ms,
            sample: cursor,
            occurred_at_ms: sample.epoch_ms,
          })
        }
        { policy_key: key, count, since_ms, latched, }
      }
    }
    progress[rule.id] = next
  }
  ({ cursor: Some(cursor), progress, }, findings)
}
