// SPDX-License-Identifier: GPL-2.0-only

///|
async fn main {
  let usage = "Usage: edgehpc inspect <health-snapshot.json>"
  match @env.args() {
    [_, "inspect", path] =>
      try {
        let sample = @fs.read_text(path)
        let report = @health.inspect_snapshot(sample)
        println(report.stringify(indent=2))
      } catch {
        error => {
          @stdio.stderr.text.write("edgehpc: \{error}\n")
          @env.exit(1)
        }
      }
    [_, "--help"] | [_, "-h"] => println(usage)
    _ => {
      @stdio.stderr.text.write(usage + "\n")
      @env.exit(2)
    }
  }
}
