use value
use fs
use path
use shell
use common

fn gnupg_dir() -> string { "/etc/pacman.d/gnupg" }

// The fingerprint, without spaces and in upper case, as gpg prints it.
fn fingerprint(params: Value) -> Result[string, string] {
    let raw = common::param_str(params, "fingerprint", "")
    let fpr = raw.replace(" ", "").to_upper()
    if (fpr.len() != 40 && fpr.len() != 64) || !fpr.chars().all(|c| (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) {
        return Err("invalid 'fingerprint' '" + raw + "': give the full 40 (or 64) hex digit fingerprint")
    }
    Ok(fpr)
}

// "missing", or the key's validity in pacman's keyring: "trusted" once it
// carries a signature from the local master key (lsign), else "untrusted".
fn state(fpr: string) -> Result[string, string] {
    let out = shell::bash("gpg --homedir " + gnupg_dir() + " --batch --with-colons --list-keys " + common::q(fpr) + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok("missing") }
    for l in out.stdout.split("\n") {
        if l.starts_with("pub:") {
            let v = l.split(":")[1]
            if v == "f" || v == "u" { return Ok("trusted") }
            return Ok("untrusted")
        }
    }
    Ok("missing")
}

fn validate(params: Value) -> Result[string, string] {
    let fpr = fingerprint(params)?
    common::one_line("keyserver", common::param_str(params, "keyserver", ""))?
    let content = common::param_str(params, "content", "")
    if content != "" && !content.contains("-----BEGIN PGP PUBLIC KEY BLOCK-----") {
        return Err("'content' is not an ASCII-armored public key")
    }
    if !fs::is_dir(gnupg_dir()) { return Err(gnupg_dir() + " does not exist: initialise pacman's keyring first (pacman-key --init)") }
    Ok(fpr)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let fpr = validate(params)?
    let s = state(fpr)?
    let ok = if common::want_present(params)? { s == "trusted" } else { s == "missing" }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let fpr = validate(params)?
    if !common::want_present(params)? {
        common::run("pacman-key --delete", "pacman-key --delete " + common::q(fpr))?
        return Ok(ApplyResult::Success)
    }
    if state(fpr)? == "missing" {
        let content = common::param_str(params, "content", "")
        if content != "" {
            let tmp = fs::temp_file()?
            fs::write(tmp, content)?
            let out = shell::bash("pacman-key --add " + common::q(tmp), Value::Null)?
            fs::delete(tmp).unwrap_or(())
            if !out.success { return Err(common::cmd_err("pacman-key --add", out)) }
        } else {
            let ks = common::param_str(params, "keyserver", "")
            let opt = if ks != "" { "--keyserver " + common::q(ks) + " " } else { "" }
            common::run("pacman-key --recv-keys", "pacman-key " + opt + "--recv-keys " + common::q(fpr))?
        }
        if state(fpr)? == "missing" { return Err("the key added does not have fingerprint " + fpr) }
    }
    common::run("pacman-key --lsign-key", "pacman-key --lsign-key " + common::q(fpr))?
    Ok(ApplyResult::Success)
}
