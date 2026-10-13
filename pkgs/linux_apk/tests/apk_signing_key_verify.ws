use value
use fs
use hash

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/apk/keys/"
    let content = fs::read(d + "cw-content.rsa.pub")?
    if !content.contains("-----BEGIN PUBLIC KEY-----") { return Err("cw-content is not the PEM key") }
    if fs::read(d + "cw-drift.rsa.pub")? != content { return Err("cw-drift was not rewritten") }
    if hash::sha256_file(d + "cw-alpine-6165ee59.rsa.pub")? != "207e4696d3c05f7cb05966aee557307151f1f00217af4143c1bcaf33b8df733f" {
        return Err("the downloaded key has the wrong hash")
    }
    if fs::exists(d + "cw-bad-hash.rsa.pub") { return Err("a key with a mismatched hash was written") }
    if fs::exists(d + ".cw-bad-hash.rsa.pub.cw-tmp") { return Err("the rejected download was left behind") }
    if fs::exists(d + "cw-old.rsa.pub") { return Err("cw-old should be removed") }
    Ok(true)
}
