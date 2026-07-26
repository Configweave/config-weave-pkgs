use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let repos = fs::read("/etc/apk/repositories")?
    Ok(
        repos.contains("https://dl-cdn.alpinelinux.org/alpine/edge/testing") &&
        !repos.contains("https://stale.invalid/alpine/v3.20/testing")
    )
}
