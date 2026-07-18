use value
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs {
                if let Some(s) = x.as_string() { items.push(s) }
            }
        }
    }
    items
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

// The JSON payload as a string list whether it carried a list or a single
// collapsed string (ConvertTo-Json in Windows PowerShell 5.1).
fn str_items(v: Value) -> List[string] {
    let items: List[string] = []
    if let Some(xs) = v.as_list() {
        for x in xs {
            if let Some(s) = x.as_string() { items.push(s) }
        }
    } else if let Some(s) = v.as_string() {
        if s != "" { items.push(s) }
    }
    items
}

fn current(iface: string) -> Result[List[string], string] {
    let out = ps_out(
        "$s = @((Get-DnsClientServerAddress -InterfaceAlias " + ps_q(iface) +
        " -AddressFamily IPv4).ServerAddresses); ConvertTo-Json -InputObject $s -Compress"
    )?
    Ok(str_items(json::parse(out)?))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let iface = param_str(params, "interface", "")
    if iface == "" { return Err("missing 'interface' parameter") }
    let want = param_list(params, "servers")
    // Order-sensitive on purpose: DNS server order is preference order.
    if current(iface)?.join(",") == want.join(",") {
        Ok(CheckResult::AlreadyConfigured)
    } else {
        Ok(CheckResult::NotConfigured)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let iface = param_str(params, "interface", "")
    if iface == "" { return Err("missing 'interface' parameter") }
    let want = param_list(params, "servers")
    if want.is_empty() {
        ps_run("Set-DnsClientServerAddress -InterfaceAlias " + ps_q(iface) + " -ResetServerAddresses")?
        return Ok(ApplyResult::Success)
    }
    let addrs = want.map(|s| ps_q(s)).join(",")
    ps_run("Set-DnsClientServerAddress -InterfaceAlias " + ps_q(iface) + " -ServerAddresses (" + addrs + ")")?
    Ok(ApplyResult::Success)
}
