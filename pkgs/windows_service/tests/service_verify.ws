use value
use json
use common

// One JSON object per service named in CW_NAMES: exists, and the fields the
// steps converged.
fn services() -> Result[Value, string] {
    let script = "$o = @{{}}\n" +
        "foreach ($n in $env:CW_NAMES.Split(',')) {{\n" +
        "  $s = Get-CimInstance -ClassName Win32_Service -Filter (\"Name='\" + $n + \"'\")\n" +
        "  if (-not $s) {{ $o[$n] = @{{ exists = $false }}; continue }}\n" +
        "  $o[$n] = @{{ exists = $true; path = [string]$s.PathName; display = [string]$s.DisplayName; description = [string]$s.Description;\n" +
        "    mode = [string]$s.StartMode; delayed = [bool]$s.DelayedAutoStart; account = [string]$s.StartName; state = [string]$s.State }}\n" +
        "}}\n" +
        "$r = Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\ConfigWeave\\windows_service\\weave-rotate' -ErrorAction SilentlyContinue\n" +
        "$o['rotate_revision'] = [string]$r.PasswordRevision\n" +
        "$o | ConvertTo-Json -Compress -Depth 4\n"
    let names = "weave-new,weave-drift,weave-paused,weave-acct,weave-rotate,weave-gone,weave-marked,Spooler"
    let out = common::run_ps(script, #{ "CW_NAMES": Value::String(names) })?
    if !out.success { return Err(common::failure("querying the test services", out)) }
    json::parse(out.stdout.trim())
}

fn field(all: Value, name: string, key: string) -> string {
    if let Some(s) = all.get(name) {
        if let Some(v) = s.get(key) {
            if let Some(t) = v.as_string() { return t }
            if let Some(b) = v.as_bool() { return if b { "true" } else { "false" } }
        }
    }
    ""
}

fn expect(all: Value, name: string, key: string, want: string) -> Result[unit, string] {
    let have = field(all, name, key)
    if have != want { return Err(name + "." + key + " is '" + have + "', expected '" + want + "'") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    let all = services()?

    expect(all, "weave-new", "path", "\"C:\\weave svc\\weave-svc.exe\" --cw new")?
    expect(all, "weave-new", "display", "Weave New Service")?
    expect(all, "weave-new", "description", "created by config-weave")?
    expect(all, "weave-new", "account", "NT AUTHORITY\\LocalService")?
    expect(all, "weave-new", "mode", "Auto")?
    expect(all, "weave-new", "delayed", "false")?
    expect(all, "weave-new", "state", "Running")?

    expect(all, "weave-drift", "path", "\"C:\\weave svc\\weave-svc.exe\" --cw drift")?
    expect(all, "weave-drift", "display", "Weave Drift Service")?
    expect(all, "weave-drift", "description", "reconciled by config-weave")?
    expect(all, "weave-drift", "mode", "Auto")?
    expect(all, "weave-drift", "delayed", "true")?
    expect(all, "weave-drift", "state", "Running")?

    expect(all, "weave-paused", "state", "Running")?
    expect(all, "weave-paused", "mode", "Auto")?
    expect(all, "weave-paused", "delayed", "false")?

    expect(all, "weave-acct", "account", ".\\weavesvc")?
    expect(all, "weave-acct", "state", "Running")?

    expect(all, "weave-rotate", "state", "Running")?
    if let Some(r) = all.get("rotate_revision") {
        if r.as_string().unwrap_or("") != "2" { return Err("weave-rotate's recorded password revision is not 2") }
    }

    expect(all, "weave-gone", "exists", "false")?
    expect(all, "weave-marked", "exists", "false")?

    expect(all, "Spooler", "state", "Stopped")?
    expect(all, "Spooler", "mode", "Disabled")?
    Ok(true)
}
