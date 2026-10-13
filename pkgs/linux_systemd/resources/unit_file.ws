use value
use fs
use path
use common

fn unit_path(name: string) -> string { "/etc/systemd/system/" + name }

// A unit file, or a file inside a drop-in or .wants directory
// (`foo.service.d/override.conf`): relative, every segment a plain name.
fn validate(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    for seg in name.split("/") { common::require_segment("name", seg)? }
    Ok(())
}

// The unit a file belongs to: itself, or the unit whose `.d`, `.wants`,
// `.requires` or `.upholds` directory holds it.
fn owning_unit(name: string) -> string {
    let first = name.split("/").get(0).unwrap_or("")
    if !name.contains("/") { return first }
    for suffix in [".d", ".wants", ".requires", ".upholds"] {
        if first.ends_with(suffix) { return first.replace(suffix, "") }
    }
    first
}

// daemon-reload needs systemd running; without it there is nothing to
// reload, and the file is read at the next boot.
fn reloading(params: Value) -> Result[bool, string] {
    if !common::param_bool(params, "daemon_reload", false) { return Ok(false) }
    Ok(common::has_systemctl()? && common::systemd_running())
}

// `content` is optional only for :absent.
fn content(params: Value) -> Result[string, string] {
    let c = common::param_str(params, "content", "")
    if c == "" { return Err("'content' is required when ensure = :present") }
    Ok(c)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    validate(name)?
    let p = unit_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) || fs::read_link(p).is_ok() { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
    } else {
        if !common::has_content(p, content(params)?) { return Ok(CheckResult::NotConfigured) }
        if reloading(params)? && common::needs_reload(owning_unit(name))? { return Ok(CheckResult::NotConfigured) }
        Ok(CheckResult::AlreadyConfigured)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    validate(name)?
    let p = unit_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) || fs::read_link(p).is_ok() { fs::delete(p)? }
        // An emptied drop-in directory goes too.
        if name.contains("/") {
            let dir = path::parent(p)
            if fs::is_dir(dir) && fs::list_dir(dir)?.is_empty() { fs::delete_dir(dir)? }
        }
        if reloading(params)? { common::daemon_reload()? }
        return Ok(ApplyResult::Success)
    }
    let body = content(params)?
    if !common::has_content(p, body) {
        fs::mkdir(path::parent(p))?
        fs::write(p, body)?
    }
    if reloading(params)? { common::daemon_reload()? }
    Ok(ApplyResult::Success)
}
