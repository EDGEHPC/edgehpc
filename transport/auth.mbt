// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror ConfigurationError {
  InvalidNodeCredentials
  InvalidControllerOrigin
}

///|
pub struct Credentials {
  priv tokens : Map[String, String]
}

///|
fn valid_node_id(id : String) -> Bool {
  id.length() >= 1 &&
  id.length() <= 64 &&
  id
  .iter()
  .all(ch => {
    match ch {
      'a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' => true
      _ => false
    }
  })
}

///|
fn valid_token(token : String) -> Bool {
  token.length() == 64 &&
  token
  .iter()
  .all(ch => {
    match ch {
      'a'..<='f' | '0'..<='9' => true
      _ => false
    }
  })
}

///|
fn check_token(token : String) -> Unit raise {
  guard valid_token(token) else { raise InvalidNodeCredentials }
}

///|
/// Each node has its own 32-byte token, encoded as lowercase hex.
pub fn parse_credentials(source : StringView) -> Credentials raise {
  let value = @json.parse(
    source,
    reject_duplicate_keys=true,
    max_nesting_depth=6,
  )
  guard value is Object(fields) &&
    fields.length() == 2 &&
    fields.get("schema_version") is Some(Number(1.0, ..)) &&
    fields.get("nodes") is Some(Object(nodes)) &&
    !nodes.is_empty() &&
    nodes.length() <= 256 else {
    raise InvalidNodeCredentials
  }
  let tokens : Map[String, String] = Map([])
  let seen : Set[String] = Set([])
  for node_id, value in nodes {
    guard valid_node_id(node_id) &&
      value is String(token) &&
      valid_token(token) &&
      !seen.contains(token) else {
      raise InvalidNodeCredentials
    }
    tokens[node_id] = token
    seen.add(token)
  }
  { tokens, }
}

///|
fn same_secret(left : String, right : String) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let mut difference = 0
  for i in 0..<left.length() {
    difference = difference |
      (left.code_unit_at(i).to_int() ^ right.code_unit_at(i).to_int())
  }
  difference == 0
}

///|
pub fn Credentials::accepts(
  self : Credentials,
  node_id : String,
  authorization : String?,
) -> Bool {
  match (self.tokens.get(node_id), authorization) {
    (Some(expected), Some(provided)) =>
      same_secret("Bearer " + expected, provided)
    _ => false
  }
}
