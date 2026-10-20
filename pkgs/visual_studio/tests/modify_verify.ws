use value
use fs
use common

fn build_tools() -> Result[Value, string] {
    let found = common::instances("Microsoft.VisualStudio.Product.BuildTools", "[17.0,18.0)", true)?
    if found.is_empty() { return Err("vswhere finds no Build Tools 2022 instance") }
    Ok(found.get(0).unwrap())
}

fn has_package(inst: Value, id: string) -> bool {
    common::get_list(inst, "packages").any(|p| common::get_str(p, "id").to_lower() == id.to_lower())
}

fn explicit(inst: Value) -> Result[List[string], string] {
    let out: List[string] = []
    for p in common::selected_packages(common::get_str(inst, "instanceId"))? {
        if common::is_explicit_selection(p) { out.push(common::get_str(p, "id").to_lower()) }
    }
    Ok(out)
}

fn verify(facts: Value) -> Result[bool, string] {
    let inst = build_tools()?
    if !has_package(inst, "Microsoft.Component.ClickOnce.MSBuild") { return Err("ClickOnce MSBuild was not added") }
    if !explicit(inst)?.contains("microsoft.component.clickonce.msbuild") { return Err("ClickOnce MSBuild is not recorded as an explicit selection") }
    Ok(true)
}
