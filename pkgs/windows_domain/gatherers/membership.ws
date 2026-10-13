use value
use common

// PowerShell that emits one JSON object describing this machine's
// domain/workgroup membership — and, when it is a DC, the FSMO roles it
// holds. The roles are read over LDAP from this DC itself (each role
// object's fSMORoleOwner against this server's NTDS Settings DN), so they
// need neither RSAT nor AD Web Services, which starts late after a reboot.
// When that read fails, fsmo_known is false and fsmo_error says why, rather
// than the roles reading as an empty list. ConvertTo-Json in Windows
// PowerShell 5.1 can collapse a nested single-element array to a scalar, so
// fsmo_roles is re-normalised on the wscript side.
fn membership_ps() -> string {
    common::dsrole_ps() +
    "$c = Get-CimInstance Win32_ComputerSystem; $ds = Get-CwDsRole; " +
    "$fsmo = @(); $known = $true; $why = ''; " +
    "if ($c.DomainRole -ge 4) {{ " +
        "try {{ " +
            "$root = [ADSI]'LDAP://localhost/RootDSE'; $me = [string]$root.dsServiceName.Value; " +
            "$dom = [string]$root.defaultNamingContext.Value; $cfg = [string]$root.configurationNamingContext.Value; $sch = [string]$root.schemaNamingContext.Value; " +
            "$objs = [ordered]@{{ PDCEmulator = $dom; RIDMaster = ('CN=RID Manager$,CN=System,' + $dom); InfrastructureMaster = ('CN=Infrastructure,' + $dom); " +
            "SchemaMaster = $sch; DomainNamingMaster = ('CN=Partitions,' + $cfg) }}; " +
            "foreach ($k in $objs.Keys) {{ $o = [ADSI]('LDAP://localhost/' + $objs[$k]); " +
            "if ([string]$o.fSMORoleOwner.Value -eq $me) {{ $fsmo += $k }} }} " +
        "}} catch {{ $known = $false; $fsmo = @(); $why = $_.Exception.Message }} " +
    "}}; " +
    "[pscustomobject]@{{ " +
        "computer_name = $env:COMPUTERNAME; " +
        "part_of_domain = [bool]$c.PartOfDomain; " +
        "domain = $(if ($c.PartOfDomain) {{ $c.Domain }} else {{ '' }}); " +
        "workgroup = $(if ($c.PartOfDomain) {{ '' }} else {{ $c.Workgroup }}); " +
        "netbios_name = $(if ($c.PartOfDomain) {{ $ds.netbios }} else {{ '' }}); " +
        "domain_role = [int]$c.DomainRole; " +
        "fsmo_roles = $fsmo; fsmo_known = $known; fsmo_error = $why " +
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
    let m = common::parse(common::ps("the membership query", membership_ps())?)?

    let role = common::get_int(m, "domain_role")
    Ok(Value::Map(#{
        "computer_name": Value::String(common::get_str(m, "computer_name")),
        "part_of_domain": Value::Bool(common::get_bool(m, "part_of_domain")),
        "domain": Value::String(common::get_str(m, "domain")),
        "workgroup": Value::String(common::get_str(m, "workgroup")),
        "netbios_name": Value::String(common::get_str(m, "netbios_name")),
        "role": Value::String(role_name(role)),
        "is_dc": Value::Bool(role >= 4),
        "fsmo_roles": get_fsmo(m),
        "fsmo_known": Value::Bool(common::get_bool(m, "fsmo_known")),
        "fsmo_error": Value::String(common::get_str(m, "fsmo_error"))
    }))
}
