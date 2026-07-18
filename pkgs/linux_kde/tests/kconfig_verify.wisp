use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let globals = fs::read("/tmp/cw-kde-home/.config/kdeglobals")?
    let kwin = fs::read("/tmp/cw-kde-home/.config/kwinrc")?
    let ksm = fs::read("/tmp/cw-kde-home/.config/ksmserverrc")?
    Ok(
        globals.contains("[KDE]") && globals.contains("SingleClick=false") &&
        globals.contains("[General][Fonts]") && globals.contains("fixed=Hack,10") &&
        kwin.contains("[Windows]") && kwin.contains("FocusPolicy=ClickToFocus") &&
        ksm.contains("loginMode=emptySession") && !ksm.contains("stale=")
    )
}
