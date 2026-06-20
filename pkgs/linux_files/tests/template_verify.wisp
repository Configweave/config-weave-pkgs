use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let text = fs::read("/tmp/cw-tmpl/app.conf")?
    Ok(text == "# cw\nservers=a,b\nenabled=yes\n")
}
