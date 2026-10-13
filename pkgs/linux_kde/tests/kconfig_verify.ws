use value
use fs

// The non-blank lines of one section, in order.
fn section(text: string, header: string) -> List[string] {
    let out = []
    let inside = false
    for line in text.split("\n") {
        let t = line.trim()
        if t.starts_with("[") { inside = t == header; continue }
        if inside && t != "" { out.push(t) }
    }
    out
}

fn expect(file: string, header: string, want: List[string]) -> Result[unit, string] {
    let got = section(fs::read("/tmp/cw-kde-home/.config/" + file)?, header)
    let g = got.join(" | ")
    let w = want.join(" | ")
    if g != w { return Err(file + " " + header + ": expected [" + w + "], got [" + g + "]") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    expect("kwinrc", "[Windows]", ["FocusPolicy=ClickToFocus", "AutoRaise=true"])?
    expect("kdeglobals", "[General]", ["fixed=General-level"])?
    expect("kdeglobals", "[General][Fonts]", ["fixedWidth=keep", "fixed=Hack,10"])?
    expect("kdeglobals", "[KDE]", ["SingleClick=true"])?
    expect("kdeglobals", "[Icons]", ["Theme=breeze"])?
    expect("ksmserverrc", "[General]", ["loginMode=emptySession", "keep=1"])?
    expect("escrc", "[E]", ["multi=\\sline1\\nline2\\\\x\\t\\s", "empty="])?
    let ksm = fs::read("/tmp/cw-kde-home/.config/ksmserverrc")?
    if ksm.contains("restoreSession") || ksm.contains("stale") { return Err("ksmserverrc still has a removed value: " + ksm) }
    if fs::exists("/tmp/cw-kde-home/.config/nosuchrc") { return Err(":absent created nosuchrc") }
    if fs::read("/tmp/cw-kde-home/.config/norl")? != "[A]\nk=v" { return Err("norl was rewritten") }
    Ok(true)
}
