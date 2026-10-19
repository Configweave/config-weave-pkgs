use value
use common

// The workload and component ids explicitly selected for an instance, or
// an empty list when its state.json cannot be read.
fn selected(instance_id: string) -> List[Value] {
    let out: List[Value] = []
    if let Ok(items) = common::selected_packages(instance_id) {
        for p in items {
            if common::is_explicit_selection(p) { out.push(Value::String(common::get_str(p, "id"))) }
        }
    }
    out
}

fn entry(inst: Value) -> Value {
    let workloads: List[Value] = []
    for p in common::get_list(inst, "packages") {
        if common::get_str(p, "type").to_lower() == "workload" { workloads.push(Value::String(common::get_str(p, "id"))) }
    }
    let id = common::get_str(inst, "instanceId")
    Value::Map(#{
        "instance_id": Value::String(id),
        "name": Value::String(common::get_str(inst, "displayName")),
        "product": Value::String(common::get_str(inst, "productId")),
        "version": Value::String(common::get_str(inst, "installationVersion")),
        "path": Value::String(common::get_str(inst, "installationPath")),
        "channel_id": Value::String(common::get_str(inst, "channelId")),
        "channel_uri": Value::String(common::get_str(inst, "channelUri")),
        "complete": Value::Bool(common::get_bool(inst, "isComplete")),
        "prerelease": Value::Bool(common::get_bool(inst, "isPrerelease")),
        "workloads": Value::List(workloads),
        "selected": Value::List(selected(id))
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let range = ""
    let v = common::param_str(params, "version", "")
    if v != "" { range = common::version_range(v)? }
    let out: List[Value] = []
    for inst in common::instances("*", range, true)? { out.push(entry(inst)) }
    Ok(Value::Map(#{
        "count": Value::Int(out.len()),
        "instances": Value::List(out)
    }))
}
