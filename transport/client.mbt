// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror TransportError {
  ResponseStatus(Int32)
  UnexpectedTask
}

///|
pub struct Client {
  origin : String
  node_id : String
  priv token : String
  timeout_ms : Int32
}

///|
fn check_authority(authority : String, loopback_only : Bool) -> Bool {
  let pieces = authority.split(":").map(part => part.to_owned()).to_array()
  let host = match pieces {
    [host] => host
    [host, port] => {
      guard !port.is_empty() && port.iter().all(d => d >= '0' && d <= '9') else {
        return false
      }
      let n = @string.parse_int(port) catch { _ => return false }
      guard n >= 1 && n <= 65535 else { return false }
      host
    }
    _ => return false
  }
  if loopback_only {
    // Require a literal address rather than resolving a possibly overridden name.
    return host == "127.0.0.1"
  }
  !host.is_empty() &&
  host
  .iter()
  .all(ch => {
    match ch {
      'a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '.' => true
      _ => false
    }
  })
}

///|
/// HTTP is allowed only on literal IPv4 loopback. Network deployments use HTTPS.
pub fn Client::Client(
  origin : String,
  node_id : String,
  token : String,
  timeout_ms~ : Int32 = 2500,
) -> Client raise {
  guard valid_node_id(node_id) else { raise InvalidNodeCredentials }
  check_token(token)
  let (prefix, loopback) = if origin.has_prefix("https://") {
    (8, false)
  } else if origin.has_prefix("http://") {
    (7, true)
  } else {
    raise InvalidControllerOrigin
  }
  let authority = origin[prefix:].to_owned()
  guard origin.length() <= 260 &&
    check_authority(authority, loopback) &&
    timeout_ms >= 1 &&
    timeout_ms <= 30000 else {
    raise InvalidControllerOrigin
  }
  { origin, node_id, token, timeout_ms, }
}

///|
fn Client::url(self : Client, resource : String) -> String {
  "\{self.origin}/v1/nodes/\{self.node_id}/\{resource}"
}

///|
fn Client::headers(self : Client) -> Map[@http.CaseInsensitiveString, String] {
  {
    "Authorization": "Bearer " + self.token,
    "Content-Type": "application/json",
    "Accept": "application/json",
  }
}

///|
/// Pull only this client's task. The server keeps offering it until completion.
pub async fn Client::pull(self : Client) -> @model.Task? {
  @async.with_timeout(self.timeout_ms, () => {
    let (response, stream) = @http.get(
      self.url("tasks/next"),
      headers=self.headers(),
    )
    defer stream.close()
    if response.code == 204 {
      return None
    }
    guard response.code == 200 else { raise ResponseStatus(response.code) }
    let task = @model.parse_task(@store.read_bounded(stream, 1024))
    guard task.node_id == self.node_id else { raise UnexpectedTask }
    Some(task)
  })
}

///|
/// Complete only after a successful HTTP response carrying the matching ACK.
/// Redirects, remote errors, oversized replies and corrupt ACKs are failures.
pub async fn Client::send(self : Client, item : @model.Delivery) -> Unit {
  guard item.node_id() == self.node_id else { raise UnexpectedTask }
  @async.with_timeout(self.timeout_ms, () => {
    let stream = @http.post(self.url("deliveries"), headers=self.headers())
    defer stream.close()
    let body = @utf8.encode(item.payload().stringify())
    stream.write(body[:])
    let response = stream.end_request()
    guard response.code == 200 else { raise ResponseStatus(response.code) }
    @model.verify_acknowledgement(@store.read_bounded(stream, 1024), item.id())
  })
}
