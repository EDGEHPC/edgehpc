// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror StoreError {
  LimitExceeded
  InvalidFile(String)
  AlreadyRunning
}

///|
pub struct Directory {
  path : String
}

///|
async fn prepare_directory(path : String) -> Unit {
  @fs.mkdir(path, permission=0o700, allow_exist=true)
  guard @fs.kind(path, follow_symlink=false) is Directory else {
    raise InvalidFile(path)
  }
}

///|
/// Exclude other node workers for this directory while still allowing status
/// readers and short state transactions. The OS releases the lease on exit.
pub async fn[X] with_worker(path : String, run : async () -> X) -> X {
  prepare_directory(path)
  let lease = @fs.open(
    path + "/.worker",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lease.close()
  guard lease.try_lock(Exclusive) else { raise AlreadyRunning }
  defer lease.unlock()
  run()
}

///|
/// Use one advisory lock for each state directory, including between processes.
/// The caller must keep the directory private. Never hold this lock over network I/O.
pub async fn[X] transaction(path : String, body : async (Directory) -> X) -> X {
  prepare_directory(path)
  let lock = @fs.open(
    path + "/.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  lock.lock(Exclusive)
  defer lock.unlock()
  body({ path, })
}

///|
/// Read at most limit bytes from a streaming request or an open file.
pub async fn read_bounded(reader : &@io.BinaryReader, limit : Int32) -> String {
  guard limit >= 0 else { raise LimitExceeded }
  let buf = Buffer()
  let chunk = FixedArray::make(8192, b'\x00')
  for ;; {
    let remaining = limit - buf.length()
    let size = reader.read_into(
      chunk,
      max_len=if remaining < 8192 { remaining + 1 } else { 8192 },
    )
    if size == 0 {
      break
    }
    guard size <= remaining else { raise LimitExceeded }
    buf.write_bytes(Bytes::from_array(chunk.exact_view(end=size))[:])
  }
  @utf8.decode(buf.to_bytes()[:])
}

///|
/// Reject symlinks, directories and pipes rather than trying to read them.
pub async fn read_file(path : String, limit : Int32) -> String {
  guard @fs.kind(path, follow_symlink=false) is Regular else {
    raise InvalidFile(path)
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  read_bounded(file, limit)
}

///|
fn Directory::entry_path(self : Directory, name : String) -> String raise {
  guard name != "" &&
    name != "." &&
    name != ".." &&
    name != ".lock" &&
    !name.contains("/") &&
    !name.contains("\u005c") else {
    raise InvalidFile(name)
  }
  self.path + "/" + name
}

///|
pub async fn Directory::read(
  self : Directory,
  name : String,
  limit : Int32,
) -> String? {
  let path = self.entry_path(name)
  Some(read_file(path, limit)) catch {
    @os_error.OsError(NotFound, ..) => None
    error => raise error
  }
}

///|
pub async fn Directory::sync(self : Directory) -> Unit {
  let dir = @fs.open(self.path, mode=ReadOnly)
  defer dir.close()
  dir.sync()
}

///|
/// Replace a single snapshot atomically after syncing it, and sync the rename.
/// The temporary name is private to the directory lock. It can survive a crash.
pub async fn Directory::write(
  self : Directory,
  name : String,
  content : String,
  limit : Int32,
) -> Unit {
  let data = @utf8.encode(content)
  guard data.length() <= limit else { raise LimitExceeded }
  let path = self.entry_path(name)
  let tmp = self.path + "/.write-in-progress"
  guard path != tmp else { raise InvalidFile(path) }
  @fs.remove(tmp, allow_missing=true)
  let file = @fs.open(
    tmp,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  )
  defer file.close()
  defer @fs.remove(tmp, allow_missing=true)
  file.write(data[:])
  file.sync()
  // No transport timeout can interrupt a successful rename before syncing its
  // directory. A real storage failure still propagates to the caller.
  @async.protect_from_cancel(() => {
    @fs.rename(tmp, path)
    self.sync()
  })
}
