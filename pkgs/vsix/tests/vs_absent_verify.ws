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
    if !vs::installed(inst, "machine", "ConfigWeave.Test.Plain")?.is_empty() { return Err("ConfigWeave.Test.Plain is still installed") }
    if !vs::installed(inst, "user", "ConfigWeave.Test.User")?.is_empty() { return Err("ConfigWeave.Test.User is still installed") }
    if !vs::installed(inst, "machine", "ConfigWeave.Test.Outer")?.is_empty() { return Err("ConfigWeave.Test.Outer is still installed") }
    if !vs::installed(inst, "machine", "d48e8f25-661b-4970-8b66-03f051ba5fc3")?.is_empty() { return Err("the Marketplace extension is still installed") }
    Ok(true)
}
