use value
use json
use common

fn gathered_version(facts: Value, name: string) -> string {
    if let Some(g) = facts.get("choco") {
        if let Some(pkgs) = g.get("packages") {
            if let Some(items) = pkgs.as_list() {
                for p in items {
                    if common::get_str(p, "name").to_lower() == name { return common::get_str(p, "version") }
                }
            }
        }
    }
    ""
}

// Packages and sources as Chocolatey reports them now, as one JSON object.
fn state() -> Result[Value, string] {
    let script = common::choco_ps() +
        "$pk = @{{}}; foreach ($l in (& $choco list --limit-output @chocoLocal)) {{ $p = ([string]$l).Trim() -split '\\|'; if ($p.Count -ge 2) {{ $pk[$p[0].ToLower()] = $p[1] }} }}\n" +
        "$src = @{{}}; foreach ($l in (& $choco source list --limit-output)) {{ $p = ([string]$l).Trim() -split '\\|'; if ($p.Count -ge 3) {{ $src[$p[0]] = $p[1] + '|' + $p[2] }} }}\n" +
        "ConvertTo-Json -Compress @{{ packages = $pk; sources = $src }}\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("reading Chocolatey state", out)) }
    json::parse(out.stdout.trim())
}

fn at(m: Value, section: string, key: string) -> string {
    if let Some(s) = m.get(section) { return common::get_str(s, key) }
    ""
}

fn verify(facts: Value) -> Result[bool, string] {
    // The gather ran after setup and before the steps.
    if gathered_version(facts, "chocolatey-core.extension") == "" { return Err("the chocolatey_packages gatherer did not list chocolatey-core.extension") }
    if gathered_version(facts, "chocolatey-dotnetfx.extension") != "1.0.1" { return Err("the gatherer did not list chocolatey-dotnetfx.extension 1.0.1") }

    let s = state()?
    if at(s, "packages", "chocolatey-core.extension") != "" { return Err("chocolatey-core.extension is still installed") }
    let held = at(s, "packages", "chocolatey-dotnetfx.extension")
    if held != "1.0.0" { return Err("chocolatey-dotnetfx.extension is '" + held + "', expected 1.0.0") }
    if at(s, "sources", "cwtest") != "https://example.com/api/v2/|False" { return Err("cwtest is '" + at(s, "sources", "cwtest") + "'") }
    if at(s, "sources", "cwdis") != "https://example.com/dis/|False" { return Err("cwdis is '" + at(s, "sources", "cwdis") + "', expected enabled") }
    if at(s, "sources", "cwgone") != "" { return Err("the cwgone source still exists") }
    Ok(true)
}
