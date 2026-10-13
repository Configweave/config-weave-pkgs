use value
use json
use common

fn gathered(facts: Value, id: string) -> bool {
    if let Some(g) = facts.get("winget") {
        if let Some(pkgs) = g.get("packages") {
            if let Some(items) = pkgs.as_list() {
                for p in items {
                    if common::get_str(p, "id") == id && common::get_str(p, "version") != "" { return true }
                }
            }
        }
    }
    false
}

fn verify(facts: Value) -> Result[bool, string] {
    // The gather ran after setup and before the steps.
    if !gathered(facts, "7zip.7zip") || !gathered(facts, "jqlang.jq") { return Err("the winget_packages gatherer did not list 7zip.7zip and jqlang.jq") }

    let script = common::winget_ps() +
        "$f = Join-Path ([IO.Path]::GetTempPath()) 'cw-verify.json'\n" +
        "$null = & $winget export --output $f --include-versions --accept-source-agreements --disable-interactivity\n" +
        "$v = @{{}}\n" +
        "foreach ($s in @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).Sources)) {{ foreach ($p in @($s.Packages)) {{ $v[$p.PackageIdentifier] = [string]$p.Version }} }}\n" +
        "$src = @(& $winget source list --disable-interactivity)\n" +
        "ConvertTo-Json -Compress @{{ sevenzip = [string]$v['7zip.7zip']; jq = [string]$v['jqlang.jq']; msstore = [bool]($src -match '^msstore\\s') }}\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("reading winget state", out)) }
    let s = json::parse(out.stdout.trim())?
    if common::get_str(s, "sevenzip") != "24.08" { return Err("7zip.7zip is '" + common::get_str(s, "sevenzip") + "', expected 24.08") }
    if common::get_str(s, "jq") != "" { return Err("jqlang.jq is still installed") }
    if common::get_bool(s, "msstore") { return Err("the msstore source still exists") }
    Ok(true)
}
