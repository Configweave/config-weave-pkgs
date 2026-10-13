use value
use common

fn prop(name: string) -> string {
    "ISNULL(CAST(SERVERPROPERTY('" + name + "') AS nvarchar(128)), '')"
}

fn gather(params: Value) -> Result[Value, string] {
    let q = "SELECT " + prop("ProductVersion") + " + '|' + " + prop("Edition") + " + '|' + " +
        prop("ProductLevel") + " + '|' + " + prop("EngineEdition") + " + '|' + " +
        prop("IsHadrEnabled") + " + '|' + " + prop("Collation") + " + '|' + " + prop("MachineName") + ";"
    let raw = common::run_scalar(params, q)?
    let f = raw.split("|")
    Ok(Value::Map(#{
        "version": Value::String(f.get(0).unwrap_or("")),
        "edition": Value::String(f.get(1).unwrap_or("")),
        "product_level": Value::String(f.get(2).unwrap_or("")),
        "engine_edition": Value::String(f.get(3).unwrap_or("")),
        "hadr_enabled": Value::String(f.get(4).unwrap_or("")),
        "collation": Value::String(f.get(5).unwrap_or("")),
        "machine": Value::String(f.get(6).unwrap_or(""))
    }))
}
