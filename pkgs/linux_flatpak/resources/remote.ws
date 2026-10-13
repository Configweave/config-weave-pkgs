use value
use shell
use common

fn validate(params: Value, present: bool) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::ident("name", name)?
    let url = common::param_str(params, "url", "")
    if url.contains("\n") || url.contains("\r") || url.contains(" ") { return Err("'url' must not contain whitespace") }
    if present && url == "" { return Err("missing 'url' parameter (required when :present)") }
    if url.starts_with("-") { return Err("'url' must not start with '-'") }
    common::scope(params)
}

// A .flatpakrepo descriptor is read once, at remote-add: the remote stores
// the repository URL inside it, not the descriptor's own URL.
fn is_descriptor(url: string) -> bool { url.ends_with(".flatpakrepo") }

// [url, options] for the remote, or [] when this installation has none.
// --show-disabled matters: Fedora ships flathub disabled, and a disabled
// remote is still configured.
fn remote(inst: string, name: string) -> Result[List[string], string] {
    let out = common::output("flatpak remotes", common::flatpak(inst, "remotes --show-disabled --columns=name,url,options"))?
    for l in out.stdout.split("\n") {
        let f = l.split("\t")
        // the options column is left off entirely when it is empty
        if f.len() >= 2 && f[0] == name { return Ok([f[1], if f.len() >= 3 { f[2] } else { "" }]) }
    }
    Ok([])
}

fn options(r: List[string]) -> List[string] { r[1].split(",").map(|o| o.trim()) }

// What differs from the wanted state, as remote-modify flags. Empty means
// converged.
fn drift(params: Value, r: List[string]) -> List[string] {
    let out = []
    let opts = options(r)
    if opts.contains("disabled") { out.push("--enable") }
    let url = common::param_str(params, "url", "")
    if !is_descriptor(url) && strip_slash(r[0]) != strip_slash(url) { out.push("--url=" + common::q(url)) }
    let gpg = common::param_bool(params, "gpg_verify", true)
    if gpg && opts.contains("no-gpg-verify") { out.push("--gpg-verify") }
    if !gpg && !opts.contains("no-gpg-verify") { out.push("--no-gpg-verify") }
    out
}

fn strip_slash(url: string) -> string {
    let u = url.trim()
    while u.ends_with("/") { u = u.slice(0, u.len() - 1) }
    u
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    let inst = validate(params, present)?
    let r = remote(inst, common::param_str(params, "name", ""))?
    let ok = if present { r.len() == 2 && drift(params, r).len() == 0 } else { r.len() == 0 }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    let inst = validate(params, present)?
    let name = common::param_str(params, "name", "")
    let r = remote(inst, name)?
    if !present {
        // flatpak refuses while apps or runtimes installed from the remote
        // remain; that refusal is the error.
        if r.len() == 2 { common::run("flatpak remote-delete", common::flatpak(inst, "remote-delete " + common::q(name)))? }
        return Ok(ApplyResult::Success)
    }
    if r.len() == 0 {
        let gpg = if common::param_bool(params, "gpg_verify", true) { "" } else { "--no-gpg-verify " }
        common::run("flatpak remote-add", common::flatpak(inst, "remote-add " + gpg + common::q(name) + " " + common::q(common::param_str(params, "url", ""))))?
        return Ok(ApplyResult::Success)
    }
    let flags = drift(params, r)
    if flags.len() > 0 {
        common::run("flatpak remote-modify", common::flatpak(inst, "remote-modify " + flags.join(" ") + " " + common::q(name)))?
    }
    Ok(ApplyResult::Success)
}
