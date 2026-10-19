use value
use env
use log
use common

// Ids every instance of a product carries whether or not anyone asked for
// them (the editor core of the IDEs, the MSBuild core of Build Tools). The
// installer refuses to remove them, so exact mode leaves them alone.
fn required_ids() -> List[string] {
    [
        "microsoft.visualstudio.workload.coreeditor",
        "microsoft.visualstudio.component.coreeditor",
        "microsoft.visualstudio.workload.msbuildtools",
        "microsoft.visualstudio.component.coreeditor.buildtools"
    ]
}

struct Spec {
    product: string,
    range: string,
    wanted: List[string],
    install_path: string,
    channel_url: string,
    bootstrapper: string,
    product_key: string,
    exact: bool,
    include_recommended: bool,
}

fn validate_product_key(key: string) -> Result[unit, string] {
    if key == "" { return Ok(()) }
    let bare = key.replace("-", "")
    let alnum = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if bare.len() != 25 || !bare.chars().all(|c| alnum.contains(str(c))) {
        return Err("'product_key' must be 25 letters and digits, optionally as five dash-separated groups")
    }
    Ok(())
}

fn spec(params: Value) -> Result[Spec, string] {
    common::want_present(params)?
    let product = common::product_param(params)?
    let range = common::version_range(common::param_str(params, "version", ""))?
    let wanted: List[string] = []
    for label in ["workloads", "components"] {
        for id in common::param_list(params, label) {
            common::validate_id(label, id)?
            if !wanted.any(|w| w.to_lower() == id.to_lower()) { wanted.push(id) }
        }
    }
    let install_path = common::param_str(params, "install_path", "")
    common::quotable("install_path", install_path)?
    let channel_url = common::param_str(params, "channel_url", "")
    common::quotable("channel_url", channel_url)?
    let bootstrapper = common::param_str(params, "bootstrapper", "")
    common::quotable("bootstrapper", bootstrapper)?
    let product_key = common::param_str(params, "product_key", "")
    validate_product_key(product_key)?
    Ok(Spec {
        product: product,
        range: range,
        wanted: wanted,
        install_path: install_path,
        channel_url: channel_url,
        bootstrapper: bootstrapper,
        product_key: product_key,
        exact: common::param_bool(params, "exact", false),
        include_recommended: common::param_bool(params, "include_recommended", false),
    })
}

// The instance this resource manages: the one at install_path when that is
// set, else the first of the product within the version range.
fn find(s: Spec) -> Result[Option[Value], string] {
    for inst in common::instances(common::product_id(s.product), s.range, true)? {
        if s.install_path == "" { return Ok(Some(inst)) }
        if common::norm_path(common::get_str(inst, "installationPath")) == common::norm_path(s.install_path) { return Ok(Some(inst)) }
    }
    Ok(None)
}

fn installed_ids(inst: Value) -> List[string] {
    let ids: List[string] = []
    for p in common::get_list(inst, "packages") {
        let id = common::get_str(p, "id")
        if id != "" { ids.push(id.to_lower()) }
    }
    ids
}

fn missing(s: Spec, inst: Value) -> List[string] {
    let have = installed_ids(inst)
    s.wanted.filter(|w| !have.contains(w.to_lower()))
}

// In exact mode: workloads and components that were explicitly selected
// for the instance (state.json's selectedPackages with userSelectedState
// Explicit) but are no longer listed. Dependencies of a listed item, and
// what a product includes by itself, are recorded as Implicit, so they are
// never removed.
fn extra(s: Spec, inst: Value) -> Result[List[string], string] {
    let out: List[string] = []
    if !s.exact { return Ok(out) }
    let wanted = s.wanted.map(|w| w.to_lower())
    let selected = common::selected_packages(common::get_str(inst, "instanceId"))
    if let Err(e) = selected {
        return Err("exact mode reads the selected workloads and components from " + common::state_file(common::get_str(inst, "instanceId")) + ", which could not be read: " + e)
    }
    for p in selected.unwrap() {
        let id = common::get_str(p, "id")
        let l = id.to_lower()
        if id == "" || wanted.contains(l) || required_ids().contains(l) { continue }
        if !common::is_explicit_selection(p) { continue }
        if !out.any(|o| o.to_lower() == l) { out.push(id) }
    }
    Ok(out)
}

// channel_url picks where the instance takes its product and updates from.
// An instance on another channel is not moved silently: that needs the
// installer's modifySettings --newChannelUri, which can change the
// product's version line.
fn channel_drift(s: Spec, inst: Value) -> Result[unit, string] {
    if s.channel_url == "" { return Ok(()) }
    let have = common::get_str(inst, "channelUri")
    if have.trim().to_lower() == s.channel_url.trim().to_lower() { return Ok(()) }
    Err("the instance at " + common::get_str(inst, "installationPath") + " takes updates from channel '" + have + "', not channel_url '" + s.channel_url + "'; move it with setup.exe modifySettings --installPath <path> --newChannelUri <url>, or set channel_url to match")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let s = spec(params)?
    let found = find(s)?
    if !common::want_present(params)? {
        if found.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if found.is_none() { return Ok(CheckResult::NotConfigured) }
    let inst = found.unwrap()
    channel_drift(s, inst)?
    if !common::get_bool(inst, "isComplete") { return Ok(CheckResult::NotConfigured) }
    if !missing(s, inst).is_empty() { return Ok(CheckResult::NotConfigured) }
    if !extra(s, inst)?.is_empty() { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// The bootstrapper for `major`: the bootstrapper param, else the
// Microsoft-hosted one for that major's channel.
fn bootstrapper(s: Spec, major: Option[int]) -> Result[string, string] {
    let src = s.bootstrapper
    if src == "" {
        if major.is_none() { return Err("'version' " + s.range + " names no major version, so set 'bootstrapper'") }
        src = common::default_bootstrapper_url(major.unwrap(), s.product)?
    }
    common::bootstrapper_file(src, s.product)
}

fn q(s: string) -> string { "\"" + s + "\"" }

fn add_args(ids: List[string], flag: string) -> string {
    let out = ""
    for id in ids { out = out + " " + flag + " " + id }
    out
}

fn install(s: Spec) -> Result[ApplyResult, string] {
    let exe = bootstrapper(s, common::range_major(s.range))?
    let args = "--quiet --wait --norestart --nocache"
    if s.install_path != "" { args = args + " --installPath " + q(s.install_path) }
    if s.channel_url != "" { args = args + " --channelUri " + q(s.channel_url) }
    if s.include_recommended { args = args + " --includeRecommended" }
    args = args + add_args(s.wanted, "--add")
    let env: Map[string, Value] = #{}
    if s.product_key != "" { env.insert("CW_PRODUCT_KEY", Value::String(s.product_key.replace("-", ""))) }
    common::run_bootstrapper(exe, args, "installing " + common::product_id(s.product), env)
}

fn instance_major(inst: Value) -> Option[int] {
    let v = common::get_str(inst, "installationVersion").split(".").get(0).unwrap_or("")
    if !common::is_digits(v) { return None }
    v.parse_int()
}

fn modify(s: Spec, inst: Value, add: List[string], remove: List[string]) -> Result[ApplyResult, string] {
    let exe = bootstrapper(s, instance_major(inst))?
    let p = common::get_str(inst, "installationPath")
    let verb = if add.is_empty() && remove.is_empty() { "repair" } else { "modify" }
    let args = verb + " --installPath " + q(p) + " --quiet --wait --norestart"
    if verb == "modify" {
        args = args + " --nocache"
        if s.include_recommended { args = args + " --includeRecommended" }
        args = args + add_args(add, "--add") + add_args(remove, "--remove")
    }
    common::run_bootstrapper(exe, args, verb + " of " + p, #{})
}

fn uninstall(s: Spec, inst: Value) -> Result[ApplyResult, string] {
    let exe = bootstrapper(s, instance_major(inst))?
    let p = common::get_str(inst, "installationPath")
    common::run_bootstrapper(exe, "uninstall --installPath " + q(p) + " --quiet --wait --norestart --force", "uninstalling " + p, #{})
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let s = spec(params)?
    if !env::is_elevated() { return Err("the Visual Studio installer must run as an administrator") }
    let found = find(s)?
    if !common::want_present(params)? {
        if found.is_none() { return Ok(ApplyResult::Success) }
        return uninstall(s, found.unwrap())
    }
    if found.is_none() {
        let res = install(s)?
        if find(s)?.is_none() {
            return Err("the bootstrapper exited " + (if res == ApplyResult::RebootRequired { "3010" } else { "0" }) + ", but vswhere finds no " + common::product_id(s.product) + " instance in " + s.range + (if s.install_path != "" { " at " + s.install_path } else { "" }))
        }
        return Ok(res)
    }
    let inst = found.unwrap()
    channel_drift(s, inst)?
    let add = missing(s, inst)
    let remove = extra(s, inst)?
    if !add.is_empty() { log::info("adding " + add.join(", ")) }
    if !remove.is_empty() { log::info("removing " + remove.join(", ")) }
    modify(s, inst, add, remove)
}
