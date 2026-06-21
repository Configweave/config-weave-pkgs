use value
use shell

// Column start offset of `key` in the header line, or -1 if absent.
fn col(header: string, key: string) -> int {
    if let Some(i) = header.find(key) { i } else { -1 }
}

// Slice [a, b) clamped to the line's bounds (body rows are often shorter than
// the header), trimmed. winget pads columns by display width, so this is a
// best-effort parse and may desync on CJK package names.
fn safe_slice(s: string, a: int, b: int) -> string {
    let n = s.len()
    let lo = if a < 0 { 0 } else if a > n { n } else { a }
    let hi = if b < 0 { 0 } else if b > n { n } else { b }
    if hi <= lo { return "" }
    s.slice(lo, hi).trim()
}

fn empty_result() -> Value {
    let none: List[Value] = []
    Value::Map(#{ "count": Value::Int(0), "packages": Value::List(none) })
}

fn gather(params: Value) -> Result[Value, string] {
    let out = shell::powershell("winget list --accept-source-agreements --disable-interactivity 2>$null", Value::Null)?
    if !out.success { return Ok(empty_result()) }

    let lines = out.stdout.split("\n")

    // The dashed separator under the header is locale-independent; the header
    // is the line directly above it. Locate the separator's index.
    let sep_idx = [-1]
    let scan = [0]
    for line in lines {
        let cur = scan.get(0).unwrap_or(0)
        scan.set(0, cur + 1)
        if sep_idx.get(0).unwrap_or(-1) >= 0 { continue }
        if line.trim().starts_with("---") { sep_idx.set(0, cur) }
    }

    let s = sep_idx.get(0).unwrap_or(-1)
    if s < 1 { return Ok(empty_result()) }

    let header = lines.get(s - 1).unwrap_or("")
    let id_i = col(header, "Id")
    let ver_i = col(header, "Version")
    if id_i < 0 || ver_i < 0 { return Ok(empty_result()) }

    // Version column ends at the next column to its right (Available, else Source).
    let avail_i = col(header, "Available")
    let src_i = col(header, "Source")
    let ver_end = if avail_i > ver_i { avail_i } else if src_i > ver_i { src_i } else { header.len() }

    let entries = []
    let idx = [0]
    for line in lines {
        let cur = idx.get(0).unwrap_or(0)
        idx.set(0, cur + 1)
        if cur <= s { continue }
        if line.trim() == "" { continue }
        let id = safe_slice(line, id_i, ver_i)
        if id == "" { continue }
        entries.push(Value::Map(#{
            "name": Value::String(safe_slice(line, 0, id_i)),
            "id": Value::String(id),
            "version": Value::String(safe_slice(line, ver_i, ver_end))
        }))
    }

    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "packages": Value::List(entries)
    }))
}
