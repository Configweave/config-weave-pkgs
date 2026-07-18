use value
use shell
use json

// PowerShell that emits one JSON object describing this machine's
// domain/workgroup membership — and, when it is a DC, the FSMO roles it
// holds. ConvertTo-Json in Windows PowerShell 5.1 can collapse a nested
// single-element array to a scalar, so fsmo_roles is re-normalised on the
// wisp side.
fn membership_ps() -> string {
    "$ErrorActionPreference='Stop'; " +
    "$c = Get-CimInstance Win32_ComputerSystem; " +
    "$fsmo = @(); $netbios = ''; " +
    "if ($c.DomainRole -ge 4) {{ " +
        "try {{ " +
            "$fsmo = @((Get-ADDomainController -Identity $env:COMPUTERNAME).OperationMasterRoles | ForEach-Object {{ \"$_\" }}); " +
            "$netbios = (Get-ADDomain).NetBIOSName " +
        "}} catch {{}} " +
    "}}; " +
    "[pscustomobject]@{{ " +
        "computer_name = $env:COMPUTERNAME; " +
        "part_of_domain = [bool]$c.PartOfDomain; " +
        "domain = $(if ($c.PartOfDomain) {{ $c.Domain }} else {{ '' }}); " +
        "workgroup = $(if ($c.PartOfDomain) {{ '' }} else {{ $c.Workgroup }}); " +
        "netbios_name = \"$netbios\"; " +
        "domain_role = [int]$c.DomainRole; " +
        "fsmo_roles = $fsmo " +
    "}} | ConvertTo-Json -Compress"
}

// Win32_ComputerSystem.DomainRole → a readable role name.
fn role_name(role: int) -> string {
    if role == 0 { return "standalone_workstation" }
    if role == 1 { return "member_workstation" }
    if role == 2 { return "standalone_server" }
    if role == 3 { return "member_server" }
    if role == 4 { return "backup_dc" }
    if role == 5 { return "primary_dc" }
    "unknown"
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(n) = v.as_int() { return n } }
    0
}

// fsmo_roles as a list of strings whether JSON carried a list, a single
// collapsed string, or nothing.
fn get_fsmo(m: Value) -> Value {
    let roles = []
    if let Some(v) = m.get("fsmo_roles") {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(s) = item.as_string() { roles.push(Value::String(s)) }
            }
        } else if let Some(s) = v.as_string() {
            if s != "" { roles.push(Value::String(s)) }
        }
    }
    Value::List(roles)
}

fn gather(params: Value) -> Result[Value, string] {
    let out = shell::powershell(membership_ps(), Value::Null)?
    if !out.success { return Err("membership query failed: " + out.stderr.trim()) }
    let m = json::parse(out.stdout.trim())?

    let role = get_int(m, "domain_role")
    Ok(Value::Map(#{
        "computer_name": Value::String(get_str(m, "computer_name")),
        "part_of_domain": Value::Bool(get_bool(m, "part_of_domain")),
        "domain": Value::String(get_str(m, "domain")),
        "workgroup": Value::String(get_str(m, "workgroup")),
        "netbios_name": Value::String(get_str(m, "netbios_name")),
        "role": Value::String(role_name(role)),
        "is_dc": Value::Bool(role >= 4),
        "fsmo_roles": get_fsmo(m)
    }))
}
