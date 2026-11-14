// SPDX-License-Identifier: GPL-2.0-only

///|
let token_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

///|
let token_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

///|
test "each node can only use its own assigned token" {
  let config = "{\"schema_version\":1,\"nodes\":{\"edge-a\":\"\{token_a}\",\"edge-b\":\"\{token_b}\"}}"
  let keys = parse_credentials(config)
  assert_true(keys.accepts("edge-a", Some("Bearer " + token_a)))
  assert_false(keys.accepts("edge-a", Some("Bearer " + token_b)))
  assert_false(keys.accepts("edge-b", None))
  assert_false(keys.accepts("../edge-a", Some("Bearer " + token_a)))
  let shared = config.replace(old=token_b, new=token_a)
  assert_true((Some(parse_credentials(shared)) catch { _ => None }) is None)
}

///|
test "the client permits HTTPS and refuses plaintext or ambiguous remote origins" {
  ignore(Client("http://127.0.0.1:8080", "edge-a", token_a))
  ignore(Client("https://controller.example:443", "edge-a", token_a))
  for
    origin in [
      "http://controller.example:8080", "http://127.0.0.10:8080", "http://127.0.0.1:0",
      "http://127.0.0.1:65536", "http://127.0.0.1@controller.example", "https://controller.example?x=1",
      "https://controller.example/other", "https://controller.example:443:80", "https://controller.example#fragment",
    ] {
    let client = Some(Client(origin, "edge-a", token_a)) catch { _ => None }
    assert_true(client is None)
  }
}
