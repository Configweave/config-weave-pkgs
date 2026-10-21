// Version ranges for `version` params, in the npm (node-semver) syntax that
// config-weave's `version` host module implements: 1.2.3 and 15.0.4490.9
// are exact, 7 and 7.4 are prefixes (7.4 = 7.4.x), plus >= > < <=, space
// AND, ||, ^, ~, x / *, and a - b. Empty or * accepts any version.
//
// The same file is kept in windows_installers, windows_packages,
// windows_powershell, mssql and vsix (lib/vrange.ws); change them together.
use value
use version

// Whether `want` accepts any installed version.
fn any(want: string) -> bool {
    let w = want.trim()
    w == "" || w == "*" || w == "x" || w == "X"
}

// Letters, digits, '.', '-', '_' and '+', not starting with '-': what a
// version pin could hold before ranges existed.
fn plain(want: string) -> bool {
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+"
    !want.starts_with("-") && want.chars().all(|c| allowed.contains(str(c)))
}

fn parses_as_range(want: string) -> bool { version::matches("0", want).is_ok() }

// A pin that is not range syntax (24.09a, 2024_01): only an installed
// version spelled the same satisfies it, as before ranges existed.
fn opaque(want: string) -> bool { !any(want) && !parses_as_range(want) && plain(want) }

// Whether `want` names one exact version: a bare version with three or more
// numeric parts (7.5.4, 15.0.4490.9, 7.6.0-preview.3). That one is
// installed directly; anything else is resolved against what is available.
fn exact(want: string) -> bool {
    if any(want) { return false }
    if let Ok(v) = version::parse(want) {
        if let Some(p) = v.get("parts") { return p.as_list().unwrap_or([]).len() >= 3 }
    }
    false
}

// A range that does not parse is an error naming `label`, quoting the
// matcher's message; an opaque legacy pin is allowed.
fn validate(label: string, want: string) -> Result[unit, string] {
    if want.contains("\n") || want.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    if any(want) || opaque(want) { return Ok(()) }
    if let Err(e) = version::matches("0", want) {
        return Err("'" + label + "' is not a valid version range: " + e + " (ranges use the npm syntax: 1.2.3 exact, 7.4 or 7.4.x any 7.4, >=14.38, >=1.2 <2, ^7, ~20.2, 1.2 - 1.4, a || b)")
    }
    Ok(())
}

// Whether the installed version `have` satisfies `want`. `what` names the
// resource and `source` where `have` was read, for the error when `have` is
// not a version the range can be matched against. An empty `have` (nothing
// recorded) satisfies only an any-version `want`; a `have` spelled exactly
// as `want` always satisfies it, without parsing either.
fn satisfies(what: string, have: string, want: string, source: string) -> Result[bool, string] {
    if any(want) { return Ok(true) }
    let h = have.trim()
    if h == "" { return Ok(false) }
    if h.to_lower() == want.trim().to_lower() { return Ok(true) }
    if opaque(want) { return Ok(false) }
    if let Err(e) = version::parse(h) {
        return Err(what + ": the installed version '" + h + "', read from " + source + ", is not a version the range '" + want + "' can be matched against (" + e + ")")
    }
    version::matches(h, want)
}

// The entries of `vs` that parse as versions, so one odd listing ("Unknown",
// a date stamp) cannot fail the whole resolution.
fn versions_only(vs: List[string]) -> List[string] {
    vs.filter(|v| version::parse(v).is_ok())
}

// The newest `n` of `vs`, newest first, for an error message.
fn newest(vs: List[string], n: int) -> List[string] {
    let sorted = versions_only(vs).clone()
    sorted.sort_by(|a, b| version::compare(b, a).unwrap_or(0))
    if sorted.len() > n { return sorted.slice(0, n) }
    sorted
}

// The newest entry of `available` that satisfies `want`. None matching is an
// error naming `what`, the range, `from` (where the list came from) and the
// newest few versions that are available.
fn pick(what: string, available: List[string], want: string, from: string) -> Result[string, string] {
    let vs = versions_only(available)
    if let Some(v) = version::max_matching(vs, want)? { return Ok(v) }
    let top = newest(vs, 5)
    let listed = if top.is_empty() { "none" } else { top.join(", ") }
    Err(what + ": no version " + from + " offers satisfies '" + want + "'; the newest available: " + listed)
}
