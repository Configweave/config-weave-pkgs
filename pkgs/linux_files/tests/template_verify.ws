use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let text = fs::read("/tmp/cw-tmpl/app.conf")?
    if text != "# cw\nservers=a,b\nenabled=yes\n" { return Err("app.conf not rendered: " + text) }
    let mode = shell::bash("stat -c '%a' /tmp/cw-tmpl/app.conf", Value::Null)?
    if mode.stdout.trim() != "644" { return Err("app.conf mode not 644") }
    if fs::exists("/tmp/cw-tmpl/old.conf") { return Err("old.conf was not removed") }
    if fs::exists("/tmp/cw-tmpl/empty.conf") { return Err("a template with no body wrote a file") }
    Ok(true)
}
