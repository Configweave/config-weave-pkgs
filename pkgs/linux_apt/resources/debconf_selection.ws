use value
use shell
use common

fn vtypes() -> List[string] { ["string", "boolean", "select", "multiselect", "note", "text", "password", "title", "error"] }

fn validate(params: Value, present: bool) -> Result[unit, string] {
    for key in ["package", "question"] {
        common::operand(key, common::param_str(params, key, ""))?
    }
    if !present { return Ok(()) }
    let vtype = common::param_str(params, "vtype", "string")
    if !vtypes().contains(vtype) {
        return Err("invalid 'vtype' value '" + vtype + "' (expected one of :" + vtypes().join(", :") + ")")
    }
    common::one_line("value", common::param_str(params, "value", ""))?
    Ok(())
}

// Every value reaches debconf through the environment, never the script
// text: a password answer must not show up in the process list.
fn env(params: Value) -> Value {
    Value::Map(#{
        "env": Value::Map(#{
            "CW_PKG": Value::String(common::param_str(params, "package", "")),
            "CW_Q": Value::String(common::param_str(params, "question", "")),
            "CW_T": Value::String(common::param_str(params, "vtype", "string")),
            "CW_V": Value::String(common::param_str(params, "value", "")),
        })
    })
}

// Each debconf-communicate reply is "<code> <text>", code 0 for success.
fn reply(line: string) -> List[string] {
    if let Some(i) = line.find(" ") { return [line.slice(0, i), line.slice(i + 1, line.len())] }
    [line, ""]
}

// The question's current answer and its type, or None when debconf has no
// such question.
fn current(params: Value) -> Result[Option[List[string]], string] {
    let cmd = "printf 'GET %s\\nMETAGET %s type\\n' \"$CW_Q\" \"$CW_Q\" | DEBIAN_FRONTEND=noninteractive debconf-communicate \"$CW_PKG\" 2>/dev/null"
    let out = shell::bash(cmd, env(params))?
    let lines = out.stdout.split("\n")
    let value = reply(lines[0])
    if value[0] != "0" { return Ok(None) }
    let vtype = if lines.len() > 1 { reply(lines[1]) } else { ["", ""] }
    Ok(Some([value[1], if vtype[0] == "0" { vtype[1] } else { "" }]))
}

fn converged(params: Value, present: bool) -> Result[bool, string] {
    let cur = current(params)?
    if !present { return Ok(cur.is_none()) }
    if let Some(c) = cur {
        return Ok(c[0] == common::param_str(params, "value", "") && c[1] == common::param_str(params, "vtype", "string"))
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    if converged(params, present)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    if present {
        // Never echo the line in an error: it may hold a password.
        let out = shell::bash("printf '%s %s %s %s\\n' \"$CW_PKG\" \"$CW_Q\" \"$CW_T\" \"$CW_V\" | debconf-set-selections", env(params))?
        if !out.success { return Err("debconf-set-selections failed (exit " + str(out.code) + ")") }
        return Ok(ApplyResult::Success)
    }
    // UNREGISTER drops this package's claim on the question; debconf deletes
    // the question once nobody owns it.
    let out = shell::bash("printf 'UNREGISTER %s\\n' \"$CW_Q\" | DEBIAN_FRONTEND=noninteractive debconf-communicate \"$CW_PKG\"", env(params))?
    if !out.success { return Err(common::cmd_err("debconf UNREGISTER", out)) }
    if current(params)?.is_some() {
        return Err(common::param_str(params, "question", "") + " is still registered by another package, so it cannot be removed on behalf of " + common::param_str(params, "package", ""))
    }
    Ok(ApplyResult::Success)
}
