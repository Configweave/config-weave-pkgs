use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let cfg = fs::read("/root/.gitconfig")?
    Ok(
        cfg.contains("name = Config Weave") && !cfg.contains("Old Name") &&
        cfg.contains("email = cw@example.invalid") &&
        cfg.contains("[branch \"main\"]") && cfg.contains("rebase = true") &&
        !cfg.contains("ui = never")
    )
}
