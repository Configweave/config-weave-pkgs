use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // firewalld itself must report the permanent port rule the test added.
    Ok(shell::bash("firewall-cmd --permanent --query-port=8443/tcp", Value::Null)?.success)
}
