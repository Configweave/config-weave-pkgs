use testlab
use value
use env
use http
use hash
use path
use fs

fn s(v: string) -> Value { Value::String(v) }
fn b(v: bool) -> Value { Value::Bool(v) }
fn i(v: int) -> Value { Value::Int(v) }

// SQL Server 2022 Developer edition ISO (SHA-256 verified). Developer is free
// and full-featured, so CDC and the rest work (Express would reject CDC).
// Override with the MSSQL_MEDIA_URL env var to pin a different build.
fn media_url() -> string {
    match env::get("MSSQL_MEDIA_URL") {
        Some(u) => u,
        None => "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso"
    }
}
fn media_sha256() -> string { "80d2cd75dd2b28098c0182f50ad86bd44f9b3a9f357c30ff617480a1497daffd" }

// Run a PowerShell snippet on the machine, failing the scenario on a non-zero exit.
fn psh(m: Machine, label: string, script: string) -> Result[bool, string] {
    let r = m.powershell(script)?
    if r.exit_code != 0 {
        return Err(label + " failed (exit " + str(r.exit_code) + "): " + r.stderr + " " + r.stdout)
    }
    Ok(true)
}

// Apply a resource and assert it converges, then re-apply and assert idempotence.
fn converge(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let r = m.apply_resource(key, props)?
    if r.status != "configured" && r.status != "already_configured" {
        return Err(key + ": " + r.status + " (" + r.message + ")")
    }
    let r2 = m.apply_resource(key, props)?
    if r2.status != "already_configured" {
        return Err(key + " is not idempotent: " + r2.status + " (" + r2.message + ")")
    }
    Ok(true)
}

fn run(lab: Lab) -> Result[bool, string] {
    lab.log("bringing up sql01 (Windows Server 2025)")
    let m = lab.machine("sql01")?

    // Stage the SQL Server Express media on the HOST (fast) and copy it into the
    // guest — the VM's NAT throughput is too slow to download it guest-side
    // within the exec timeout. The mssql.instance resource still performs the
    // actual silent install from this media.
    lab.log("downloading SQL Server Developer media on the host")
    let local = path::join(fs::temp_dir()?, "SQLServer2022-Dev.iso")
    http::download(media_url(), local, Value::Null)?
    let got = hash::sha256_file(local)?
    if got != media_sha256() {
        return Err("media checksum mismatch: expected " + media_sha256() + " got " + got)
    }

    lab.log("copying media into the guest")
    psh(m, "prepare dirs", "New-Item -ItemType Directory -Force -Path C:\\media,C:\\sqlsetup | Out-Null")?
    m.copy_in(local, "C:\\media\\sql.iso")?

    lab.log("mounting media")
    psh(m, "mount media",
        "$ErrorActionPreference='Stop'; " +
        "$img = Mount-DiskImage -ImagePath C:\\media\\sql.iso -PassThru; " +
        "$drive = ($img | Get-Volume).DriveLetter; " +
        "Copy-Item -Path ($drive + ':\\*') -Destination C:\\sqlsetup -Recurse -Force; " +
        "Dismount-DiskImage -ImagePath C:\\media\\sql.iso | Out-Null; " +
        "if(-not (Test-Path C:\\sqlsetup\\SETUP.EXE)){throw 'setup.exe not found in media'}")?

    lab.log("installing SQL Server with mssql.instance (silent)")
    let install = Value::Map(#{
        "setup_path": s("C:\\sqlsetup\\SETUP.EXE"),
        "features": s("SQLENGINE"),
        "edition": s("Developer"),
        "security_mode": s("SQL"),
        "sa_password": s("Str0ng!Passw0rd"),
        "tcp_enabled": b(true),
        "instance_name": s("MSSQLSERVER")
    })
    let r = m.apply_resource("mssql.instance", install)?
    if r.status == "reboot_required" {
        m.reboot()?
        let r2 = m.apply_resource("mssql.instance", install)?
        if r2.status != "configured" && r2.status != "already_configured" {
            return Err("instance did not converge after reboot: " + r2.status + " (" + r2.message + ")")
        }
    } else if r.status != "configured" && r.status != "already_configured" {
        return Err("instance install failed: " + r.status + " (" + r.message + ")")
    }
    let rc = m.apply_resource("mssql.instance", install)?
    if rc.status != "already_configured" {
        return Err("instance is not idempotent: " + rc.status + " (" + rc.message + ")")
    }
    lab.log("SQL Server installed")

    // Install sqlcmd for the config resources: winget first (per-user alias, may
    // be missing under the SYSTEM context the guest agent runs in), else the
    // go-sqlcmd MSI. Both land sqlcmd at C:\Program Files\sqlcmd\sqlcmd.exe.
    lab.log("installing sqlcmd")
    psh(m, "install sqlcmd",
        "$ErrorActionPreference='Stop'; " +
        "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; " +
        "$winget=Get-Command winget -ErrorAction SilentlyContinue; " +
        "if($winget){ winget install --id sqlcmd --exact --silent --accept-package-agreements --accept-source-agreements } " +
        "if(-not (Test-Path 'C:\\Program Files\\sqlcmd\\sqlcmd.exe')){ " +
        "  $rel=Invoke-RestMethod -UseBasicParsing https://api.github.com/repos/microsoft/go-sqlcmd/releases/latest; " +
        "  $a=$rel.assets | Where-Object { $_.name -like '*amd64.msi' } | Select-Object -First 1; " +
        "  if(-not $a){throw 'no go-sqlcmd msi asset found'}; " +
        "  Invoke-WebRequest -UseBasicParsing $a.browser_download_url -OutFile C:\\media\\sqlcmd.msi; " +
        "  Start-Process msiexec.exe -ArgumentList '/i','C:\\media\\sqlcmd.msi','/qn' -Wait " +
        "} " +
        "if(-not (Test-Path 'C:\\Program Files\\sqlcmd\\sqlcmd.exe')){throw 'sqlcmd not installed'}")?

    lab.log("converging configuration")
    let db = Value::Map(#{
        "name": s("weave_app_db"), "recovery_model": s("SIMPLE"),
        "sql_user": s("sa"), "sql_password": s("Str0ng!Passw0rd")
    })
    converge(m, "mssql.database", db)?

    let setting = Value::Map(#{
        "name": s("cost threshold for parallelism"), "value": i(50),
        "sql_user": s("sa"), "sql_password": s("Str0ng!Passw0rd")
    })
    converge(m, "mssql.server_setting", setting)?

    let cdc = Value::Map(#{
        "database": s("weave_app_db"), "enabled": b(true),
        "sql_user": s("sa"), "sql_password": s("Str0ng!Passw0rd")
    })
    converge(m, "mssql.database_cdc", cdc)?

    lab.log("install + configuration converged")
    Ok(true)
}
