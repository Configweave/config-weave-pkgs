use value
use fs
use common
use vs

fn community() -> Result[Value, string] {
    let found = vs::instances("Microsoft.VisualStudio.Product.Community", "[17.0,18.0)")?
    if found.is_empty() { return Err("vswhere finds no Visual Studio Community 2022") }
    Ok(found.get(0).unwrap())
}

fn versions(inst: Value, scope: string, id: string) -> Result[List[string], string] {
    Ok(vs::installed(inst, scope, id)?.map(|f| common::get_str(f, "version")))
}

fn verify(facts: Value) -> Result[bool, string] {
    let inst = community()?
    let ide = common::get_str(inst, "installationPath") + "\\Common7\\IDE\\Extensions"
    let plain = vs::installed(inst, "machine", "ConfigWeave.Test.Plain")?
    if plain.is_empty() { return Err("ConfigWeave.Test.Plain is not installed per machine") }
    if !common::norm_path(common::get_str(plain.get(0).unwrap(), "dir")).starts_with(common::norm_path(ide)) { return Err("ConfigWeave.Test.Plain is not under " + ide) }
    if vs::installed(inst, "user", "ConfigWeave.Test.User")?.is_empty() { return Err("ConfigWeave.Test.User is not installed per user") }
    if !vs::installed(inst, "machine", "ConfigWeave.Test.User")?.is_empty() { return Err("ConfigWeave.Test.User went per machine") }
    let nested = versions(inst, "machine", "ConfigWeave.Test.Nested")?
    if !nested.any(|v| common::same_version(v, "2.0")) { return Err("ConfigWeave.Test.Nested 2.0 is not installed, found " + nested.join(", ")) }
    if vs::installed(inst, "machine", "d48e8f25-661b-4970-8b66-03f051ba5fc3")?.is_empty() { return Err("the Marketplace extension (Add New File) is not installed") }
    if !vs::installed(inst, "machine", "ConfigWeave.Test.Other")?.is_empty() { return Err("the wrong_id step installed something") }
    Ok(true)
}
