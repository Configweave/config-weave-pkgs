use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn dnf_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/microdnf") { return Ok("microdnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("no dnf-family package manager found (dnf5, dnf, microdnf or yum)")
}

// The stamp file's mtime records the last refresh this resource performed.
fn stamp_path() -> string { "/var/lib/config-weave/dnf-cache-updated" }

// "30m" / "24h" / "7d" / "90s" -> seconds
fn parse_span(span: string) -> Result[int, string] {
    let s = span.trim()
    if s.len() < 2 { return Err("invalid 'max_age' value '" + span + "' (expected e.g. 30m, 24h or 7d)") }
    let unit = s.slice(s.len() - 1, s.len())
    let mult = if unit == "s" { 1 } else if unit == "m" { 60 } else if unit == "h" { 3600 } else if unit == "d" { 86400 } else { 0 }
    if mult == 0 { return Err("invalid 'max_age' unit '" + unit + "' (expected s, m, h or d)") }
    if let Some(n) = s.slice(0, s.len() - 1).parse_int() {
        if n > 0 { return Ok(n * mult) }
    }
    Err("invalid 'max_age' value '" + span + "' (expected e.g. 30m, 24h or 7d)")
}

fn now() -> Result[int, string] {
    let out = shell::bash("date +%s", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if let Some(n) = out.stdout.trim().parse_int() { return Ok(n) }
    Err("could not parse `date +%s` output")
}

fn last_refresh() -> Result[int, string] {
    let meta = fs::metadata(stamp_path())?
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Err("stamp file has no modification time")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let max_age = parse_span(param_str(params, "max_age", "24h"))?
    if !fs::is_file(stamp_path()) { return Ok(CheckResult::NotConfigured) }
    if now()? - last_refresh()? > max_age { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let bin = dnf_bin()?
    // microdnf has no -y for makecache
    let cmd = if bin == "microdnf" { "microdnf makecache" } else { bin + " makecache -y" }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    fs::write(stamp, bin + "\n")?
    Ok(ApplyResult::Success)
}
