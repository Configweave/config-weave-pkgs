use value
use log
use common

// The subsystem symbol as msdb spells it.
fn subsystem(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "subsystem", "tsql")
    if s == "tsql" { return Ok("TSQL") }
    if s == "cmdexec" { return Ok("CmdExec") }
    if s == "powershell" { return Ok("PowerShell") }
    Err("invalid 'subsystem' value '" + s + "' (expected :tsql, :cmdexec or :powershell)")
}

// Exact (binary) comparison for free text, which the default
// case-insensitive collation would otherwise call equal.
fn same_text(col: string, value: string) -> string {
    "CAST(" + col + " AS varbinary(max)) = CAST(" + common::tsql_lit(value) + " AS varbinary(max))"
}

// msdb stores an empty description as its "No description available."
// message (FORMATMESSAGE(14571), localised), so both count as empty.
fn description_cond(desc: string) -> string {
    if desc != "" { return same_text("j.description", desc) }
    "(ISNULL(j.description, N'') = N'' OR j.description = FORMATMESSAGE(14571))"
}

// HH:MM:SS as the HHMMSS integer msdb stores.
fn start_time(params: Value) -> Result[int, string] {
    let t = common::param_str(params, "schedule_time", "00:00:00")
    let parts = t.split(":")
    if parts.len() != 3 { return Err("invalid 'schedule_time' '" + t + "' (expected HH:MM:SS)") }
    let h = parts[0].parse_int().unwrap_or(-1)
    let m = parts[1].parse_int().unwrap_or(-1)
    let s = parts[2].parse_int().unwrap_or(-1)
    if h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59 { return Err("invalid 'schedule_time' '" + t + "' (expected HH:MM:SS)") }
    Ok(h * 10000 + m * 100 + s)
}

fn weekday_mask(params: Value) -> Result[int, string] {
    let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    let bits = [1, 2, 4, 8, 16, 32, 64]
    let mask = 0
    for d in common::csv(common::param_str(params, "schedule_days", "")) {
        let key = if d.len() >= 3 { d.to_lower().slice(0, 3) } else { d }
        let Some(i) = names.index_of(key) else {
            return Err("invalid day '" + d + "' in 'schedule_days' (expected mon, tue, wed, thu, fri, sat, sun)")
        }
        mask = mask + bits[i]
    }
    if mask == 0 { return Err("schedule = :weekly needs 'schedule_days', e.g. \"mon,wed,fri\"") }
    Ok(mask)
}

// The managed schedule as sp_add_jobschedule arguments, in the order
// [freq_type, freq_interval, freq_subday_type, freq_subday_interval,
// freq_recurrence_factor, active_start_time]. None when schedules are
// unmanaged; an empty list for :none (no schedule at all).
fn schedule(params: Value) -> Result[Option[List[int]], string] {
    let kind = common::param_str(params, "schedule", "unmanaged")
    if kind == "unmanaged" { return Ok(None) }
    if kind == "none" { return Ok(Some([])) }
    let at = start_time(params)?
    let every = common::param_int(params, "schedule_interval", 1)
    if every < 1 { return Err("'schedule_interval' must be at least 1") }
    if kind == "daily" { return Ok(Some([4, 1, 1, 0, 0, at])) }
    if kind == "hourly" { return Ok(Some([4, 1, 8, every, 0, at])) }
    if kind == "minutes" { return Ok(Some([4, 1, 4, every, 0, at])) }
    if kind == "weekly" { return Ok(Some([8, weekday_mask(params)?, 1, 0, 1, at])) }
    Err("invalid 'schedule' value '" + kind + "' (expected :unmanaged, :none, :daily, :weekly, :hourly or :minutes)")
}

fn job_id_sql(name: string) -> string {
    "(SELECT job_id FROM msdb.dbo.sysjobs WHERE name = " + common::tsql_lit(name) + ")"
}

fn schedule_check(sch: List[int]) -> List[string] {
    let attached = "FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id WHERE js.job_id = j.job_id"
    if sch.is_empty() { return ["schedule", "NOT EXISTS (SELECT 1 " + attached + ")"] }
    ["schedule", "(SELECT COUNT(*) " + attached + ") = 1 AND EXISTS (SELECT 1 " + attached +
        " AND s.enabled = 1 AND s.freq_type = " + str(sch[0]) + " AND s.freq_interval = " + str(sch[1]) +
        " AND s.freq_subday_type = " + str(sch[2]) + " AND s.freq_subday_interval = " + str(sch[3]) +
        " AND s.freq_recurrence_factor = " + str(sch[4]) + " AND s.active_start_time = " + str(sch[5]) + ")"]
}

fn checks(params: Value, name: string) -> Result[List[List[string]], string] {
    let sub = subsystem(params)?
    let command = common::param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    let jid = "j.job_id"
    let step = "FROM msdb.dbo.sysjobsteps st WHERE st.job_id = " + jid + " AND st.step_id = 1"
    let step_cond = "EXISTS (SELECT 1 " + step + " AND " + same_text("st.step_name", common::param_str(params, "step_name", "Step 1")) +
        " AND st.subsystem = " + common::tsql_lit(sub) + " AND " + same_text("st.command", command) +
        (if sub == "TSQL" { " AND st.database_name = " + common::tsql_lit(common::param_str(params, "database", "master")) } else { "" }) + ")"
    let out = [
        ["enabled", "j.enabled = " + common::tsql_bool(common::param_bool(params, "enabled", true))],
        ["description", description_cond(common::param_str(params, "description", ""))],
        ["steps", "(SELECT COUNT(*) FROM msdb.dbo.sysjobsteps st WHERE st.job_id = " + jid + ") = 1"],
        ["step", step_cond],
        ["target_server", "EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers sv WHERE sv.job_id = " + jid + " AND sv.server_id = 0)"]
    ]
    let owner = common::param_str(params, "owner", "")
    if owner != "" { out.push(["owner", "SUSER_SNAME(j.owner_sid) = " + common::tsql_lit(owner)]) }
    if let Some(sch) = schedule(params)? { out.push(schedule_check(sch)) }
    Ok(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::require(params, "name")?
    if !common::want_present(params)? {
        let r = common::run_scalar(params, "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = " + common::tsql_lit(name) +
            ") THEN 'PRESENT' ELSE 'GONE' END;")?
        if r == "GONE" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let from = "FROM msdb.dbo.sysjobs j WHERE j.name = " + common::tsql_lit(name)
    let Some(d) = common::drift(params, from, checks(params, name)?)? else { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("job '" + name + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::require(params, "name")?
    let lit = common::tsql_lit(name)
    if !common::want_present(params)? {
        common::run_exec(params, "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = " + lit + ") " +
            "EXEC msdb.dbo.sp_delete_job @job_name = " + lit + ";")?
        return Ok(ApplyResult::Success)
    }
    checks(params, name)?
    let sub = subsystem(params)?
    let command = common::tsql_lit(common::param_str(params, "command", ""))
    let step_name = common::tsql_lit(common::param_str(params, "step_name", "Step 1"))
    let enabled = common::tsql_bool(common::param_bool(params, "enabled", true))
    let desc = common::tsql_lit(common::param_str(params, "description", ""))
    let owner = common::param_str(params, "owner", "")
    let owner_arg = if owner != "" { ", @owner_login_name = " + common::tsql_lit(owner) } else { "" }
    let db_arg = if sub == "TSQL" { ", @database_name = " + common::tsql_lit(common::param_str(params, "database", "master")) } else { "" }
    let step_args = ", @step_name = " + step_name + ", @subsystem = " + common::tsql_lit(sub) + ", @command = " + command + db_arg

    // Create the job, or bring an existing one's properties and single step
    // back in line: extra steps are deleted, step 1 is updated or added.
    let job = "DECLARE @jid uniqueidentifier = " + job_id_sql(name) + "; DECLARE @n int; " +
        "IF @jid IS NULL BEGIN " +
        "EXEC msdb.dbo.sp_add_job @job_name = " + lit + ", @enabled = " + enabled + ", @description = " + desc + owner_arg + "; " +
        "SET @jid = " + job_id_sql(name) + "; END " +
        "ELSE EXEC msdb.dbo.sp_update_job @job_id = @jid, @enabled = " + enabled + ", @description = " + desc + owner_arg + "; " +
        "WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps WHERE job_id = @jid AND step_id > 1) BEGIN " +
        "SELECT @n = MAX(step_id) FROM msdb.dbo.sysjobsteps WHERE job_id = @jid; " +
        "EXEC msdb.dbo.sp_delete_jobstep @job_id = @jid, @step_id = @n; END; " +
        "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps WHERE job_id = @jid AND step_id = 1) " +
        "EXEC msdb.dbo.sp_update_jobstep @job_id = @jid, @step_id = 1" + step_args + ", @on_success_action = 1; " +
        "ELSE EXEC msdb.dbo.sp_add_jobstep @job_id = @jid" + step_args + "; " +
        "IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers WHERE job_id = @jid AND server_id = 0) " +
        "EXEC msdb.dbo.sp_add_jobserver @job_id = @jid, @server_name = N'(LOCAL)'; "

    // A managed schedule is replaced wholesale: every schedule attached to the
    // job is detached (and deleted when nothing else uses it), then the
    // desired one is added under the job's name.
    let sched = if let Some(sch) = schedule(params)? {
        let reset = "DECLARE @sch int; " +
            "WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules WHERE job_id = @jid) BEGIN " +
            "SELECT TOP (1) @sch = schedule_id FROM msdb.dbo.sysjobschedules WHERE job_id = @jid; " +
            "EXEC msdb.dbo.sp_detach_schedule @job_id = @jid, @schedule_id = @sch, @delete_unused_schedule = 1; END; "
        let add = if sch.is_empty() { "" } else {
            "EXEC msdb.dbo.sp_add_jobschedule @job_id = @jid, @name = " + lit + ", @enabled = 1" +
                ", @freq_type = " + str(sch[0]) + ", @freq_interval = " + str(sch[1]) +
                ", @freq_subday_type = " + str(sch[2]) + ", @freq_subday_interval = " + str(sch[3]) +
                ", @freq_recurrence_factor = " + str(sch[4]) + ", @active_start_time = " + str(sch[5]) + "; "
        }
        let cur = common::drift(params, "FROM msdb.dbo.sysjobs j WHERE j.name = " + lit, [schedule_check(sch)])?
        let in_sync = if let Some(d) = cur { d.is_empty() } else { false }
        if in_sync { "" } else { reset + add }
    } else { "" }
    common::run_exec(params, job + sched)?
    Ok(ApplyResult::Success)
}
