use value
use common
use collection

// ---------------------------------------------------------------------------
// One native module registration. Server-wide: globalModules is not
// delegated. The module resource enables a registered module in the
// pipeline; this one only registers the DLL.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/globalModules")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["name", "name", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["image", "image", "str"],
        ["precondition", "preCondition", "str"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

// IIS attributes this resource owns outright: written even when
// empty, so an inherited value can be cleared rather than kept.
fn always_write() -> List[string] { [] }

fn spec(params: Value) -> Result[CollectionSpec, string] {
    Ok(CollectionSpec {
        section: section(params)?,
        collection: collection(params)?,
        scope: scope(params)?,
        keys: keys(params)?,
        attrs: attrs(params)?,
        syms: sym_map(),
        always_write: always_write(),
        required: ["image"],
        create_required: [],
    })
}

// Unregistering a native module that a <modules> entry still names stops
// every worker process that loads that configuration from starting, so the
// removal is refused until those entries are gone. Only applicationHost.config
// is searched — server level and every <location> — since a site's own
// web.config may be anywhere on disk.
fn still_used(params: Value) -> Result[unit, string] {
    if common::want_present(params)? { return Ok(()) }
    let name = common::param_str(params, "name", "")
    let where_used = common::ps_out(
        "$x = New-Object xml; $x.Load((Join-Path $env:windir 'system32\\inetsrv\\config\\applicationHost.config')); " +
        "@($x.SelectNodes('//system.webServer/modules/add') | Where-Object {{ $_.GetAttribute('name') -eq " +
        common::ps_q(name) + " }} | ForEach-Object {{ $l = $_.SelectSingleNode('ancestor::location'); " +
        "if ($null -eq $l) {{ '(server)' }} else {{ $l.GetAttribute('path') }} }}) -join ', '")?
    if where_used == "" { return Ok(()) }
    Err("global module '" + name + "' is still enabled in <modules> at " + where_used +
        "; remove it there with windows_iis.module first")
}

fn check(params: Value) -> Result[CheckResult, string] {
    still_used(params)?
    collection::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    still_used(params)?
    collection::apply(params, spec(params)?)
}
