use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // nft and ufw themselves must show the state the resources converged to.
    let rule = shell::bash(
        "nft list chain inet cwtest input | grep -q 'tcp dport 8080 accept'",
        Value::Null,
    )?
    let ufw = shell::bash("ufw show added | grep -qF 'ufw allow 9090/tcp'", Value::Null)?
    Ok(rule.success && ufw.success)
}
