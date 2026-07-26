use value
use service

fn verify(facts: Value) -> Result[bool, string] {
    // The registered test service exists (status readable) and was never
    // started; Spooler ended stopped with manual startup.
    if service::status("weave-testsvc")? != "stopped" { return Ok(false) }
    if service::status("Spooler")? != "stopped" { return Ok(false) }
    Ok(service::startup("Spooler")? == "manual")
}
