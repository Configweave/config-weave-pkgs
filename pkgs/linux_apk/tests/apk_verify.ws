use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let want = "https://dl-cdn.alpinelinux.org/alpine/v3.20/main\n#https://dl-cdn.alpinelinux.org/alpine/v3.20/community\nhttps://dl-cdn.alpinelinux.org/alpine/edge/testing\nhttps://dl-cdn.alpinelinux.org/alpine/v3.20/community\n"
    let have = fs::read("/etc/apk/repositories")?
    if have != want { return Err("/etc/apk/repositories is\n" + have + "\nwanted\n" + want) }
    Ok(true)
}
