// SPDX-License-Identifier: GPL-2.0-only

///|
async test "directory snapshots are bounded, atomically replaced and reopenable" {
  let path = @fs.tmpdir(prefix="edgehpc-state")
  defer @fs.rmdir(path, recursive=true)
  transaction(path, dir => {
    assert_eq(dir.read("record", 20), None)
    dir.write("record", "first", 5)
    assert_eq(dir.read("record", 5), Some("first"))
    let rejected = try {
      dir.write("record", "too long", 5)
      false
    } catch {
      LimitExceeded => true
      _ => false
    }
    assert_true(rejected)
    assert_eq(dir.read("record", 5), Some("first"))
    dir.write("record", "new", 5)
  })
  transaction(path, dir => assert_eq(dir.read("record", 3), Some("new")))
}

///|
async test "an interrupted staging file cannot replace the committed record" {
  let path = @fs.tmpdir(prefix="edgehpc-stale")
  defer @fs.rmdir(path, recursive=true)
  transaction(path, dir => dir.write("record", "committed", 40))
  @fs.write_text(path + "/.write-in-progress", "partial", create_mode=CreateNew)
  transaction(path, dir => {
    assert_eq(dir.read("record", 40), Some("committed"))
    dir.write("record", "replacement", 40)
    assert_eq(dir.read("record", 40), Some("replacement"))
  })
}
