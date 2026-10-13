use value
use common

fn ident(params: Value) -> Result[string, string] {
    let family = common::nft_family(params)?
    let name = common::param_str(params, "name", "")
    common::nft_name("name", name)?
    Ok(common::nft_ref(family, [name]))
}

fn check(params: Value) -> Result[CheckResult, string] {
    common::require_nft()?
    let id = ident(params)?
    let exists = common::nft_list("", "table " + id)?.is_some()
    if exists == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_nft()?
    let id = ident(params)?
    let verb = if common::want_present(params)? { "add" } else { "delete" }
    let out = common::nft_script(verb + " table " + id, verb + " table " + id, "")?
    Ok(ApplyResult::Success)
}
