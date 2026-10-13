use value
use json
use common

fn gathered(facts: Value, name: string) -> bool {
    if let Some(g) = facts.get("scoop") {
        if let Some(pkgs) = g.get("packages") {
            if let Some(items) = pkgs.as_list() {
                for p in items {
                    if common::get_str(p, "name") == name && common::get_str(p, "version") != "" { return true }
                }
            }
        }
    }
    false
}

fn verify(facts: Value) -> Result[bool, string] {
    // The gather ran after setup and before the steps.
    if !gathered(facts, "git") || !gathered(facts, "which") { return Err("the scoop_packages gatherer did not list git and which with versions") }

    let script = common::scoop_root_ps() +
        "$o = @{{}}\n" +
        "$o.nonportable = Test-Path -LiteralPath (Join-Path $scoopRoot 'buckets\\nonportable')\n" +
        "$o.cwgone = Test-Path -LiteralPath (Join-Path $scoopRoot 'buckets\\cwgone')\n" +
        "$o.cwurl = [string](Select-String -LiteralPath (Join-Path $scoopRoot 'buckets\\cwurl\\.git\\config') -Pattern 'url\\s*=' -List).Line\n" +
        "$o.jq = Test-Path -LiteralPath (Join-Path $scoopRoot 'apps\\jq\\current')\n" +
        "$o.which = Test-Path -LiteralPath (Join-Path $scoopRoot 'apps\\which\\current')\n" +
        "$o.stamp = Test-Path -LiteralPath (Join-Path $scoopRoot 'config-weave\\cache-updated')\n" +
        "ConvertTo-Json -Compress $o\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("reading scoop state", out)) }
    let s = json::parse(out.stdout.trim())?
    if !common::get_bool(s, "nonportable") { return Err("the nonportable bucket was not added") }
    if common::get_bool(s, "cwgone") { return Err("the cwgone bucket still exists") }
    if !common::get_str(s, "cwurl").contains("github.com/ScoopInstaller/PHP") { return Err("cwurl's origin is '" + common::get_str(s, "cwurl") + "'") }
    if !common::get_bool(s, "jq") { return Err("jq is not installed") }
    if common::get_bool(s, "which") { return Err("which is still installed") }
    if !common::get_bool(s, "stamp") { return Err("the refresh stamp is not under the scoop root") }
    Ok(true)
}
