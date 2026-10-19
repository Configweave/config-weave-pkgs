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
// Override with the MSSQL_MEDIA_URL env var to pin a different build, or
// MSSQL_MEDIA_PATH to use an ISO already on the host; MSSQL_MEDIA_SHA256 is
// then the digest to check it against (2019 Developer works too).
fn media_url() -> string {
    match env::get("MSSQL_MEDIA_URL") {
        Some(u) => u,
        None => "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso"
    }
}
fn media_sha256() -> string {
    match env::get("MSSQL_MEDIA_SHA256") {
        Some(h) => h.to_lower(),
        None => "80d2cd75dd2b28098c0182f50ad86bd44f9b3a9f357c30ff617480a1497daffd"
    }
}

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

// The process id of a service, "0" when it is not running.
fn service_pid(m: Machine, name: string) -> Result[string, string] {
    let r = m.powershell("(Get-CimInstance Win32_Service -Filter \"Name='" + name + "'\").ProcessId")?
    if r.exit_code != 0 { return Err("reading the process id of " + name + ": " + r.stderr) }
    Ok(r.stdout.trim())
}

// The engine and SQL Server Agent, which depends on it, as [engine pid, agent pid].
fn engine_and_agent(m: Machine) -> Result[List[string], string] {
    Ok([service_pid(m, "MSSQLSERVER")?, service_pid(m, "SQLSERVERAGENT")?])
}

// After a step that restarts the engine (common::win_restart_engine, which
// uses service::restart with stop_dependents): both services run again, and
// both run in new processes, so the engine really restarted and Agent was
// stopped for it and started again rather than left alone.
fn assert_restarted(m: Machine, what: string, before: List[string]) -> Result[bool, string] {
    let after = engine_and_agent(m)?
    if after[0] == "0" || after[0] == "" { return Err(what + ": the engine (MSSQLSERVER) is not running afterwards") }
    if after[1] == "0" || after[1] == "" { return Err(what + ": SQL Server Agent was left stopped") }
    if after[0] == before[0] { return Err(what + ": the engine did not restart (process " + before[0] + " still running)") }
    if after[1] == before[1] { return Err(what + ": SQL Server Agent was not restarted with the engine (process " + before[1] + " still running)") }
    Ok(true)
}

fn run(lab: Lab) -> Result[bool, string] {
    lab.log("bringing up sql01 (Windows Server 2025)")
    let m = lab.machine("sql01")?

    // Stage the SQL Server Express media on the HOST (fast) and copy it into the
    // guest — the VM's NAT throughput is too slow to download it guest-side
    // within the exec timeout. The mssql.instance resource still performs the
    // actual silent install from this media.
    let local = match env::get("MSSQL_MEDIA_PATH") {
        Some(p) => p,
        None => {
            lab.log("downloading SQL Server Developer media on the host")
            let p = path::join(fs::temp_dir()?, "SQLServer2022-Dev.iso")
            http::download(media_url(), p, Value::Null)?
            p
        }
    }
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
        "if(-not (Test-Path C:\\sqlsetup\\SETUP.EXE)){{throw 'setup.exe not found in media'}}")?

    // This driver sticks to the symbol defaults: Windows authentication,
    // with every T-SQL resource connecting
    // through integrated auth as the guest agent (an Administrators member,
    // hence sysadmin).
    lab.log("installing SQL Server with mssql.instance (silent)")
    let install = Value::Map(#{
        "setup_path": s("C:\\sqlsetup\\SETUP.EXE"),
        "features": s("SQLENGINE"),
        "edition": s("Developer"),
        "tcp_enabled": b(true),
        "instance": s("MSSQLSERVER")
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
    // sqlcmd is there for the T-SQL resources: SQL Server 2022 setup ships
    // the ODBC one, and install_tools adds go-sqlcmd when it is missing.
    psh(m, "sqlcmd installed", "if(-not ((Test-Path 'C:\\Program Files\\sqlcmd\\sqlcmd.exe') -or (Test-Path 'C:\\Program Files\\Microsoft SQL Server\\Client SDK\\ODBC\\*\\Tools\\Binn\\SQLCMD.EXE'))){{throw 'sqlcmd not installed'}}")?
    lab.log("SQL Server installed")

    // SQL Server Agent depends on the engine, and the SCM will not stop the
    // engine while it runs, so every restart below must stop Agent first and
    // start it again (service::restart with stop_dependents).
    psh(m, "start agent", "Set-Service SQLSERVERAGENT -StartupType Manual; Start-Service SQLSERVERAGENT")?

    // Reconcile the existing instance: a new backup directory (registry +
    // engine restart, with Agent running) and an extra sysadmin account (T-SQL).
    psh(m, "backup dir", "New-Item -ItemType Directory -Force -Path C:\\SQLBackup | Out-Null")?
    let before_reconcile = engine_and_agent(m)?
    let reinstall = Value::Map(#{
        "setup_path": s("C:\\sqlsetup\\SETUP.EXE"),
        "backup_dir": s("C:\\SQLBackup"),
        "sql_sysadmin_accounts": s("BUILTIN\\Administrators,NT AUTHORITY\\SYSTEM")
    })
    converge(m, "mssql.instance", reinstall)?
    assert_restarted(m, "instance reconcile (backup_dir)", before_reconcile)?

    lab.log("converging configuration")
    let db = Value::Map(#{
        "name": s("weave_app_db"), "compatibility_level": i(150)
    })
    converge(m, "mssql.database", db)?

    let setting = Value::Map(#{
        "name": s("cost threshold for parallelism"), "value": i(50)
    })
    converge(m, "mssql.server_setting", setting)?

    let cdc = Value::Map(#{
        "database": s("weave_app_db")
    })
    converge(m, "mssql.database_cdc", cdc)?

    // The TCP restart stops SQL Server Agent with the engine; it must come
    // back, and the dynamic port must be cleared.
    let before_tcp = engine_and_agent(m)?
    let tcp = Value::Map(#{ "port": i(14330) })
    converge(m, "mssql.tcp", tcp)?
    assert_restarted(m, "mssql.tcp", before_tcp)?

    // Enabling HADR restarts the engine, with Agent still running, and the
    // group is created in the same run.
    let before_ag = engine_and_agent(m)?
    let ag = Value::Map(#{
        "name": s("cw_ag")
    })
    converge(m, "mssql.availability_group", ag)?
    assert_restarted(m, "availability_group (HADR)", before_ag)?

    lab.log("install + configuration converged")
    Ok(true)
}
