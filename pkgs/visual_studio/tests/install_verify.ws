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
    if !common::get_bool(inst, "isComplete") { return Err("the Build Tools instance is not complete") }
    if !has_package(inst, "Microsoft.VisualStudio.Workload.MSBuildTools") { return Err("the MSBuild workload is not installed") }
    if common::get_str(inst, "channelUri") != "https://aka.ms/vs/17/release/channel" { return Err("channelUri is " + common::get_str(inst, "channelUri")) }
    // The bootstrapper was kept, and no response file (product key) was
    // left behind.
    if fs::glob("C:\\ProgramData\\config-weave\\visual_studio\\*\\vs_buildtools.exe")?.is_empty() { return Err("the bootstrapper was not kept") }
    if !fs::glob("C:\\ProgramData\\config-weave\\visual_studio\\response-*")?.is_empty() { return Err("a response directory was left behind") }
    if !fs::glob("C:\\ProgramData\\config-weave\\visual_studio\\*\\*.part")?.is_empty() { return Err("a partial download was left behind") }
    Ok(true)
}
