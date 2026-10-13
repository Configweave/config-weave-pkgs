use value
use log
use common

fn validate(params: Value) -> Result[string, string] {
    let domain = common::param_str(params, "domain_name", "")
    common::domain_name("domain_name", domain)?
    let nb = common::param_str(params, "netbios_name", "")
    if nb != "" { common::domain_name("netbios_name", nb)? }
    for key in ["site_name", "forest_mode", "domain_mode", "database_path", "log_path", "sysvol_path"] {
        common::single_line(key, common::param_str(params, key, ""))?
    }
    common::credential(params)?
    Ok(domain)
}

fn mode(params: Value) -> Result[string, string] {
    let m = common::param_str(params, "mode", "auto")
    if m == "auto" || m == "new_forest" || m == "additional" { return Ok(m) }
    Err("invalid 'mode' value '" + m + "' (expected :auto, :new_forest or :additional)")
}

fn secrets(params: Value) -> Map[string, Value] {
    #{
        "CW_SAFE_MODE": Value::String(common::param_str(params, "safe_mode_password", "")),
        "CW_CRED_PW": Value::String(common::param_str(params, "credential_password", "")),
        "CW_LOCAL_ADMIN": Value::String(common::param_str(params, "local_admin_password", ""))
    }
}

// A functional level as the number AD stores (msDS-Behavior-Version), from
// the names Install-ADDSForest accepts or a number.
fn level_ps() -> string {
    "function Level($m) {{ $s = [string]$m; $n = 0; if ([int]::TryParse($s, [ref]$n)) {{ return $n }}; " +
    "$map = @{{ 'win2008' = 3; 'windows2008forest' = 3; 'windows2008domain' = 3; " +
    "'win2008r2' = 4; 'windows2008r2forest' = 4; 'windows2008r2domain' = 4; " +
    "'win2012' = 5; 'windows2012forest' = 5; 'windows2012domain' = 5; " +
    "'win2012r2' = 6; 'windows2012r2forest' = 6; 'windows2012r2domain' = 6; " +
    "'winthreshold' = 7; 'win2016' = 7; 'windows2016forest' = 7; 'windows2016domain' = 7; " +
    "'win2025' = 10; 'windows2025forest' = 10; 'windows2025domain' = 10 }}; " +
    "$k = $s.ToLower(); if ($map.ContainsKey($k)) {{ return $map[$k] }}; throw ('unknown functional level ' + $s) }}; "
}

fn dir_eq(param: string, current_ps: string) -> string {
    "((" + current_ps + ").TrimEnd('\\') -ieq " + common::ps_q(param) + ".TrimEnd('\\'))"
}

// PowerShell collecting, into $drift, the params a promoted DC no longer
// matches. Only site_name can be changed after promotion (it is moved with
// Move-ADDirectoryServer); every other one is fixed by the promotion itself,
// so its drift is reported as an error rather than ignored.
fn drift_ps(params: Value) -> string {
    let out = "$drift = @(); $ntds = Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NTDS\\Parameters'; "
    let site = common::param_str(params, "site_name", "")
    if site != "" {
        out = out + "$site = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name; " +
            "if ($site -ne " + common::ps_q(site) + ") {{ $drift += 'site_name' }}; "
    }
    let nb = common::param_str(params, "netbios_name", "")
    if nb != "" { out = out + "if ($ds.netbios -ne " + common::ps_q(nb) + ") {{ $drift += 'netbios_name' }}; " }
    let dbp = common::param_str(params, "database_path", "")
    if dbp != "" { out = out + "if (-not " + dir_eq(dbp, "Split-Path $ntds.'DSA Database file'") + ") {{ $drift += 'database_path' }}; " }
    let lp = common::param_str(params, "log_path", "")
    if lp != "" { out = out + "if (-not " + dir_eq(lp, "$ntds.'Database log files path'") + ") {{ $drift += 'log_path' }}; " }
    let sv = common::param_str(params, "sysvol_path", "")
    if sv != "" {
        out = out + "if (-not " + dir_eq(sv, "Split-Path (Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Netlogon\\Parameters').SysVol") + ") {{ $drift += 'sysvol_path' }}; "
    }
    let fm = common::param_str(params, "forest_mode", "")
    let dm = common::param_str(params, "domain_mode", "")
    if fm != "" || dm != "" { out = out + level_ps() + "$root = [ADSI]'LDAP://RootDSE'; " }
    if fm != "" { out = out + "if ([int]$root.forestFunctionality.Value -ne (Level " + common::ps_q(fm) + ")) {{ $drift += 'forest_mode' }}; " }
    if dm != "" { out = out + "if ([int]$root.domainFunctionality.Value -ne (Level " + common::ps_q(dm) + ")) {{ $drift += 'domain_mode' }}; " }
    let dns = common::param_bool(params, "install_dns", true)
    out = out + "if ([bool](Get-Service -Name DNS -ErrorAction SilentlyContinue) -ne " + common::ps_bool(dns) + ") {{ $drift += 'install_dns' }}; "
    out
}

// 'REBOOT', 'OTHER' (not a DC of this domain) or a JSON list of drifted
// params (empty when converged). The domain is matched by its DNS or NetBIOS
// name, case-insensitively.
fn probe(params: Value, domain: string, present: bool) -> Result[string, string] {
    let drift = if present { drift_ps(params) } else { "$drift = @(); " }
    common::ps("reading this machine's domain controller role",
        common::dsrole_ps() + common::pending_ps("domain_controller") +
        "$ds = Get-CwDsRole; " +
        "if ($pending -or $ds.role_reboot) {{ 'REBOOT' }} " +
        "elseif ($ds.role -lt 4 -or ($ds.dns -ine " + common::ps_q(domain) + " -and $ds.netbios -ine " + common::ps_q(domain) + ")) {{ 'OTHER' }} " +
        "else {{ " + drift + "ConvertTo-Json -InputObject @($drift) -Compress }}")
}

fn drifted(st: string) -> Result[List[string], string] {
    let out: List[string] = []
    let v = common::parse(st)?
    if let Some(items) = v.as_list() {
        for item in items { if let Some(s) = item.as_string() { out.push(s) } }
    } else if let Some(s) = v.as_string() { out.push(s) }
    Ok(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let domain = validate(params)?
    mode(params)?
    let present = common::want_present(params)?
    let st = probe(params, domain, present)?
    if st == "REBOOT" { return Ok(CheckResult::RebootRequired) }
    if !present {
        // Only a DC of *this* domain is demoted; a DC of another domain is
        // not this step's business.
        if st == "OTHER" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "OTHER" { return Ok(CheckResult::NotConfigured) }
    let drift = drifted(st)?
    for d in drift {
        if d != "site_name" {
            return Err("this DC no longer matches '" + d + "', which is fixed when the DC is promoted and cannot be changed by this resource" +
                (if d == "forest_mode" || d == "domain_mode" { " (raising a functional level is irreversible; do it deliberately with Set-ADForestMode/Set-ADDomainMode)" } else { "" }))
        }
    }
    if !drift.is_empty() { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// PowerShell binding $exists (a DC for the domain answers the locator, the
// way a join would ask) and $resolves (the name resolves in DNS at all).
fn discover_ps(domain: string) -> string {
    // Through cmd, so nltest's stderr never reaches PowerShell, which turns
    // a native command's stderr into a terminating error under Stop.
    "& cmd.exe /c " + common::ps_q("nltest /dsgetdc:" + domain + " >nul 2>&1") + "; $exists = ($LASTEXITCODE -eq 0); " +
    "$resolves = [bool](Resolve-DnsName -Name " + common::ps_q(domain) + " -ErrorAction SilentlyContinue); "
}

fn guard_ps() -> string {
    "if (-not (Get-Module -ListAvailable ADDSDeployment)) {{ throw 'the ADDSDeployment module is missing: install the AD-Domain-Services feature (with its management tools) before promoting' }}; " +
    "Import-Module ADDSDeployment; "
}

fn smp_ps() -> string { "$smp = ConvertTo-SecureString $env:CW_SAFE_MODE -AsPlainText -Force; " }

fn opt(params: Value, key: string, flag: string) -> string {
    let v = common::param_str(params, key, "")
    if v != "" { " -" + flag + " " + common::ps_q(v) } else { "" }
}

fn promote(params: Value, domain: string) -> Result[ApplyResult, string] {
    if common::param_str(params, "safe_mode_password", "") == "" { return Err("promotion needs 'safe_mode_password'") }
    let m = mode(params)?
    let cred = common::credential(params)?
    let paths = opt(params, "database_path", "DatabasePath") + opt(params, "log_path", "LogPath") + opt(params, "sysvol_path", "SysvolPath")
    let dns = " -InstallDns:" + common::ps_bool(common::param_bool(params, "install_dns", true))
    // A credential means "join the existing domain" under :auto, and
    // :additional always does; neither may fall through to creating a forest.
    let additional = m == "additional" || (m == "auto" && cred.is_some())
    let qd = common::ps_q(domain)
    let body = if additional {
        let user = if let Some(c) = cred { c[0] } else { return Err("joining '" + domain + "' as an additional DC needs 'credential_user' and 'credential_password'") }
        log::info("promoting this server as an additional DC of " + domain)
        "if (-not $exists) {{ throw ('no domain controller for ' + " + qd + " + ' can be found; point this server''s DNS at one before promoting it as an additional DC') }}; " +
        guard_ps() + smp_ps() + common::cred_ps(user) +
        "Install-ADDSDomainController -DomainName " + qd + " -Credential $cred -SafeModeAdministratorPassword $smp" +
        dns + opt(params, "site_name", "SiteName") + paths + " -Force -NoRebootOnCompletion -WarningAction SilentlyContinue | Out-Null; "
    } else {
        log::info("creating the forest " + domain + " (first DC)")
        let guard = if m == "new_forest" {
            "if ($exists) {{ throw ('a domain controller for ' + " + qd + " + ' already answers; refusing to create a second forest of the same name') }}; "
        } else {
            "if ($exists) {{ throw ('the domain ' + " + qd + " + ' already exists; joining it as an additional DC needs credential_user and credential_password') }}; " +
            "if ($resolves) {{ throw (" + qd + " + ' resolves in DNS but no domain controller answers for it; fix DNS, or set mode = :new_forest to create the forest regardless') }}; "
        }
        guard + guard_ps() + smp_ps() +
        "Install-ADDSForest -DomainName " + qd + " -SafeModeAdministratorPassword $smp" + dns +
        opt(params, "netbios_name", "DomainNetbiosName") + opt(params, "forest_mode", "ForestMode") + opt(params, "domain_mode", "DomainMode") +
        paths + " -Force -NoRebootOnCompletion -WarningAction SilentlyContinue | Out-Null; "
    }
    // Discovery runs before the module guard, so a wrong mode is reported as
    // such even on a server that could not have promoted anyway.
    common::ps_env("promoting this server to a domain controller",
        discover_ps(domain) + body + common::mark_ps("domain_controller"),
        secrets(params))?
    Ok(ApplyResult::RebootRequired)   // DC promotion always needs a reboot to finish
}

// A promoted DC in the wrong site is moved; that needs no reboot.
fn move_site(params: Value) -> Result[ApplyResult, string] {
    let site = common::param_str(params, "site_name", "")
    log::info("moving this DC to site " + site)
    common::ps("moving this DC to site '" + site + "'",
        "Import-Module ActiveDirectory; " +
        "Move-ADDirectoryServer -Identity $env:COMPUTERNAME -Site " + common::ps_q(site))?
    Ok(ApplyResult::Success)
}

fn demote(params: Value) -> Result[ApplyResult, string] {
    if common::param_str(params, "local_admin_password", "") == "" {
        return Err("demoting a DC needs 'local_admin_password' (the machine's local Administrator password after demotion)")
    }
    let cred = common::credential(params)?
    let creds = if let Some(c) = cred { common::cred_ps(c[0]) + "$o = @{{ Credential = $cred }}; " } else { "$o = @{{}}; " }
    // The last DC takes the domain (and its partitions / DNS zone) with it.
    let o_last = if common::param_bool(params, "last_dc_in_domain", false) {
        " -LastDomainControllerInDomain -RemoveApplicationPartitions -IgnoreLastDnsServerForZone"
    } else { "" }
    let o_force = if common::param_bool(params, "force_removal", false) { " -ForceRemoval" } else { "" }
    log::info("demoting this domain controller")
    common::ps_env("demoting this domain controller",
        guard_ps() + creds +
        "$lap = ConvertTo-SecureString $env:CW_LOCAL_ADMIN -AsPlainText -Force; " +
        "Uninstall-ADDSDomainController @o -LocalAdministratorPassword $lap" +
        o_last + o_force + " -Force -NoRebootOnCompletion -WarningAction SilentlyContinue | Out-Null; " +
        common::mark_ps("domain_controller"),
        secrets(params))?
    Ok(ApplyResult::RebootRequired)   // demotion always needs a reboot to finish
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let domain = validate(params)?
    let present = common::want_present(params)?
    let st = probe(params, domain, present)?
    if st == "REBOOT" { return Ok(ApplyResult::RebootRequired) }
    if !present {
        if st == "OTHER" { return Ok(ApplyResult::Success) }
        return demote(params)
    }
    if st == "OTHER" { return promote(params, domain) }
    move_site(params)
}
