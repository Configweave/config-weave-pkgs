use testlab
use value
use env
use http
use hash
use path
use fs

fn s(v: string) -> Value { Value::String(v) }
fn i(v: int) -> Value { Value::Int(v) }

// SQL Server 2019 Developer (Analysis Services and Master Data Services; MDS
// is the reason for 2019: mssql.mds_* refuse anything newer) and the SSRS
// 2019 installer. Both are fetched on the host, which is much faster than
// the VM's NAT, and checked against their SHA-256. MSSQL2019_ISO and
// SSRS2019_EXE point at local copies to skip the download.
fn iso_url() -> string { "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLServer2019-x64-ENU-Dev.iso" }
fn iso_sha256() -> string { "575d5f32bce655cf6fa3c3a0f5a525adfcab3a5469107ef8f05bf92c43741218" }
fn ssrs_url() -> string { "https://download.microsoft.com/download/1/a/a/1aaa9177-3578-4931-b8f3-373b24f63342/SQLServerReportingServices.exe" }
fn ssrs_sha256() -> string { "178ccba5a39fd574b30178c48e3cac7c88e5ececb7d5b8d74e0abf49f6c18680" }

// A download is checked against `sha` by http::download itself; a local
// copy named by `var` is hashed here.
fn staged(lab: Lab, var: string, url: string, name: string, sha: string) -> Result[string, string] {
    if let Some(local) = env::get(var) {
        let got = hash::sha256_file(local)?
        if got != sha { return Err(name + " checksum mismatch: expected " + sha + " got " + got) }
        return Ok(local)
    }
    let p = path::join(fs::temp_dir()?, name)
    lab.log("downloading " + name + " on the host")
    http::download(url, p, Value::Map(#{ "retries": Value::Int(3), "sha256": Value::String(sha) }))?
    Ok(p)
}

fn psh(m: Machine, label: string, script: string) -> Result[string, string] {
    let r = m.powershell(script)?
    if r.exit_code != 0 {
        return Err(label + " failed (exit " + str(r.exit_code) + "): " + r.stderr + " " + r.stdout)
    }
    Ok(r.stdout.trim())
}

// Apply until the resource stops asking for a reboot, rebooting in between;
// then it must report configured or already_configured.
fn apply_rebooting(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let n = 0
    loop {
        let r = m.apply_resource(key, props)?
        if r.status == "reboot_required" && n < 2 {
            m.reboot()?
            n = n + 1
            continue
        }
        if r.status != "configured" && r.status != "already_configured" {
            return Err(key + ": " + r.status + " (" + r.message + ")")
        }
        return Ok(true)
    }
}

// Converge, then assert a second apply finds nothing to do.
fn converge(m: Machine, key: string, props: Value) -> Result[bool, string] {
    apply_rebooting(m, key, props)?
    let r2 = m.apply_resource(key, props)?
    if r2.status != "already_configured" {
        return Err(key + " is not idempotent: " + r2.status + " (" + r2.message + ")")
    }
    Ok(true)
}

// A check that must fail, with `needle` in its message.
fn refuses(m: Machine, key: string, props: Value, needle: string) -> Result[bool, string] {
    let r = m.check_resource(key, props)?
    if r.status != "error" || !r.message.contains(needle) {
        return Err(key + " should have refused (" + needle + "), got " + r.status + " (" + r.message + ")")
    }
    Ok(true)
}

// HTTP status of a URL fetched inside the guest as the given local user
// ("" = the agent's own Windows credentials).
fn http_status(m: Machine, user: string, password: string, url: string) -> Result[string, string] {
    if user == "" {
        return psh(m, "GET " + url, "try {{ (Invoke-WebRequest -UseBasicParsing -UseDefaultCredentials " + url + ").StatusCode }} catch {{ [int]$_.Exception.Response.StatusCode }}")
    }
    psh(m, "GET " + url, "curl.exe -s -o NUL -w '%{{http_code}}' --ntlm -u " + user + ":" + password + " " + url)
}

fn expect_status(m: Machine, user: string, password: string, url: string, want: string) -> Result[bool, string] {
    let got = http_status(m, user, password, url)?
    if got != want { return Err("GET " + url + " returned " + got + ", want " + want) }
    Ok(true)
}

fn run(lab: Lab) -> Result[bool, string] {
    let iso = staged(lab, "MSSQL2019_ISO", iso_url(), "SQLServer2019-x64-ENU-Dev.iso", iso_sha256())?
    let ssrs = staged(lab, "SSRS2019_EXE", ssrs_url(), "SQLServerReportingServices.exe", ssrs_sha256())?

    lab.log("bringing up bi01 (Windows Server 2025)")
    let m = lab.machine("bi01")?
    psh(m, "prepare dirs", "New-Item -ItemType Directory -Force -Path C:\\media,C:\\sql2019,C:\\ASBackup | Out-Null")?
    m.copy_in(iso, "C:\\media\\sql2019.iso")?
    m.copy_in(ssrs, "C:\\media\\SQLServerReportingServices.exe")?
    psh(m, "unpack media",
        "$ErrorActionPreference='Stop'; $img = Mount-DiskImage -ImagePath C:\\media\\sql2019.iso -PassThru; " +
        "$d = ($img | Get-Volume).DriveLetter; Copy-Item -Path ($d + ':\\*') -Destination C:\\sql2019 -Recurse -Force; " +
        "Dismount-DiskImage -ImagePath C:\\media\\sql2019.iso | Out-Null; Remove-Item C:\\media\\sql2019.iso")?
    // MDS prerequisites (IIS role services) and the Windows users MDS needs:
    // it refuses built-in accounts for its application pool.
    psh(m, "IIS for MDS",
        "$r = Install-WindowsFeature -Name Web-Server,Web-Mgmt-Console,Web-Asp-Net45,Web-Default-Doc,Web-Dir-Browsing,Web-Http-Errors," +
        "Web-Static-Content,Web-Http-Logging,Web-Request-Monitor,Web-Stat-Compression,Web-Filtering,Web-Windows-Auth,Web-Net-Ext45," +
        "Web-ISAPI-Ext,Web-ISAPI-Filter,NET-WCF-HTTP-Activation45,WAS-Process-Model,WAS-Config-APIs; if (-not $r.Success) {{ throw 'IIS install failed' }}")?
    psh(m, "MDS users",
        "foreach ($u in 'mds_admin', 'mds_svc') {{ if (-not (Get-LocalUser $u -ErrorAction SilentlyContinue)) {{ " +
        "New-LocalUser $u -Password (ConvertTo-SecureString 'Md5!Passw0rd12' -AsPlainText -Force) -PasswordNeverExpires | Out-Null }} }}")?
    let host = psh(m, "hostname", "$env:COMPUTERNAME")?
    let setup = s("C:\\sql2019\\setup.exe")

    // --- #36: the engine, then two Analysis Services instances -------------
    lab.log("installing the engine with MDS")
    converge(m, "mssql.instance", Value::Map(#{ "setup_path": setup, "features": s("SQLENGINE,MDS") }))?
    lab.log("installing Analysis Services ASMD (multidimensional)")
    // Before the fix this was never detected (Instance Names\OLAP), so the
    // second apply ran setup again and converge failed.
    converge(m, "mssql.instance", Value::Map(#{ "setup_path": setup, "instance": s("ASMD"), "features": s("AS") }))?
    lab.log("installing Analysis Services ASTAB (tabular)")
    converge(m, "mssql.instance", Value::Map(#{
        "setup_path": setup, "instance": s("ASTAB"), "features": s("AS"),
        "as_server_mode": s("tabular"), "as_collation": s("Latin1_General_CI_AI"),
        "as_sysadmin_accounts": s("BUILTIN\\Administrators,NT AUTHORITY\\SYSTEM")
    }))?
    let mode = psh(m, "ASTAB mode", "([xml](Get-Content 'C:\\Program Files\\Microsoft SQL Server\\MSAS15.ASTAB\\OLAP\\Config\\msmdsrv.ini')).ConfigurationSettings.DeploymentMode")?
    if mode != "2" { return Err("ASTAB DeploymentMode is " + mode + ", want 2 (tabular)") }
    lab.log("reconciling ASMD: collation, backup directory, administrators")
    converge(m, "mssql.instance", Value::Map(#{
        "setup_path": setup, "instance": s("ASMD"), "features": s("AS"),
        "as_collation": s("Latin1_General_CS_AS"), "as_backup_dir": s("C:\\ASBackup"),
        "as_sysadmin_accounts": s("BUILTIN\\Administrators,NT AUTHORITY\\NETWORK SERVICE")
    }))?
    refuses(m, "mssql.instance", Value::Map(#{ "setup_path": setup, "instance": s("ASMD"), "features": s("AS"), "as_server_mode": s("tabular") }), "server mode is fixed by setup")?

    // --- #47: an AS server property with a restart ---------------------------
    lab.log("raising ASMD ThreadPool\\Process\\MaxThreads")
    converge(m, "mssql.analysis_services_setting", Value::Map(#{ "instance": s("ASMD"), "setting": s("ThreadPool\\Process\\MaxThreads"), "value": s("512") }))?
    psh(m, "ASMD restarted and running", "if ((Get-Service 'MSOLAP$ASMD').Status -ne 'Running') {{ throw 'MSOLAP$ASMD is not running' }}")?

    // --- #44: Reporting Services ----------------------------------------------
    // SQL setup leaves a reboot pending, and the SSRS installer then exits
    // 3010 without installing: apply_rebooting reboots and applies again.
    lab.log("installing Reporting Services 2019")
    let rs = Value::Map(#{ "setup_path": s("C:\\media\\SQLServerReportingServices.exe"), "version": s("15.0") })
    converge(m, "mssql.reporting_services", rs)?
    refuses(m, "mssql.reporting_services", Value::Map(#{ "setup_path": s("C:\\media\\SQLServerReportingServices.exe"), "install_dir": s("D:\\SSRS") }), "install folder")?
    lab.log("configuring Reporting Services on port 8081")
    converge(m, "mssql.reporting_services_config", Value::Map(#{ "web_service_url": s("http://+:8081"), "web_portal_url": s("http://+:8081") }))?
    expect_status(m, "", "", "http://localhost:8081/reports/api/v2.0/System", "200")?
    lab.log("reconfiguring: new catalogue, port, portal vdir and service account")
    converge(m, "mssql.reporting_services_config", Value::Map(#{
        "database_name": s("ReportServer2"), "web_service_url": s("http://+:8082"), "web_portal_url": s("http://+:8082"),
        "web_portal_vdir": s("Reports2"), "service_account": s("NT AUTHORITY\\NetworkService")
    }))?
    expect_status(m, "", "", "http://localhost:8082/reports2/api/v2.0/System", "200")?
    psh(m, "8081 released", "if (netsh http show urlacl | Select-String ':8081/') {{ throw 'the 8081 URL reservations were not released' }}")?

    // --- #45: Master Data Services ----------------------------------------------
    lab.log("creating the MDS database and web application")
    converge(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB"), "administrator": s(host + "\\mds_admin"), "collation": s("Latin1_General_CI_AS") }))?
    let web = Value::Map(#{
        "site": s("MDS"), "port": i(8080), "identity": s(host + "\\mds_admin"), "password": s("Md5!Passw0rd12"), "database": s("MDS_LAB")
    })
    converge(m, "mssql.mds_web_application", web)?
    expect_status(m, "mds_admin", "Md5!Passw0rd12", "http://localhost:8080/Service/Service.svc", "200")?
    lab.log("moving the MDS site to another port, identity and database")
    converge(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB2"), "administrator": s(host + "\\mds_admin") }))?
    converge(m, "mssql.mds_web_application", Value::Map(#{
        "site": s("MDS"), "port": i(8090), "identity": s(host + "\\mds_svc"), "password": s("Md5!Passw0rd12"), "database": s("MDS_LAB2")
    }))?
    expect_status(m, "mds_admin", "Md5!Passw0rd12", "http://localhost:8090/Service/Service.svc", "200")?
    refuses(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB"), "administrator": s(host + "\\mds_svc") }), "no supported way to change it")?
    refuses(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB"), "administrator": s(host + "\\mds_admin"), "mds_version": s("160") }), "2019 and older")?
    psh(m, "fake MDS 2022", "New-Item -ItemType Directory -Force -Path 'C:\\Program Files\\Microsoft SQL Server\\160\\Master Data Services\\WebApplication\\bin' | Out-Null; " +
        "Set-Content -Path 'C:\\Program Files\\Microsoft SQL Server\\160\\Master Data Services\\WebApplication\\bin\\Microsoft.MasterDataServices.Configuration.dll' -Value x")?
    refuses(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB"), "administrator": s(host + "\\mds_admin") }), "found 160")?
    psh(m, "remove fake MDS 2022", "Remove-Item -Recurse -Force 'C:\\Program Files\\Microsoft SQL Server\\160'")?

    // --- removal ------------------------------------------------------------------
    lab.log("removing the MDS site and databases, SSRS and ASTAB")
    converge(m, "mssql.mds_web_application", Value::Map(#{ "site": s("MDS"), "app_pool": s("MDS Application Pool"), "ensure": s("absent") }))?
    converge(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB"), "ensure": s("absent") }))?
    converge(m, "mssql.mds_database", Value::Map(#{ "name": s("MDS_LAB2"), "ensure": s("absent") }))?
    converge(m, "mssql.reporting_services", Value::Map(#{ "ensure": s("absent") }))?
    converge(m, "mssql.instance", Value::Map(#{ "setup_path": setup, "instance": s("ASTAB"), "features": s("AS"), "ensure": s("absent") }))?
    psh(m, "removed",
        "Import-Module WebAdministration; $bad = @(); " +
        "if (Get-Website -Name MDS) {{ $bad += 'site MDS' }}; " +
        "if (Get-Service SQLServerReportingServices -ErrorAction SilentlyContinue) {{ $bad += 'SSRS service' }}; " +
        "if (Get-Service 'MSOLAP$ASTAB' -ErrorAction SilentlyContinue) {{ $bad += 'MSOLAP$ASTAB' }}; " +
        "if ((Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\OLAP').ASTAB) {{ $bad += 'Instance Names\\OLAP\\ASTAB' }}; " +
        "if ($bad) {{ throw ('still present: ' + ($bad -join ', ')) }}")?
    lab.log("Analysis Services, Reporting Services and Master Data Services converged")
    Ok(true)
}
