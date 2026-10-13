use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$r = $null; try {{ $r = Get-NetFirewallRule -Name 'weave-rm-rule' }} catch {{ }}; if ($r) {{ 'weave-rm-rule still exists' }} else {{ '' }}")?
    if out != "" { return Err(out) }
    Ok(true)
}
