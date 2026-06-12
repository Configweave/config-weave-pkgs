use value
use fs

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") {
        if l == line { return true }
    }
    false
}

fn verify(facts: Value) -> Result[bool, string] {
    let root = "/tmp/cw-kde-home"
    let kdeglobals = fs::read(root + "/.config/kdeglobals")?
    let kwinrc = fs::read(root + "/.config/kwinrc")?
    let plasmarc = fs::read(root + "/.config/plasmarc")?
    Ok(
        kdeglobals.contains("[KDE]")
        && has_line(kdeglobals, "SingleClick=false")
        && has_line(kdeglobals, "widgetStyle=Breeze")
        && kwinrc.contains("[Windows]")
        && has_line(kwinrc, "FocusPolicy=ClickToFocus")
        && plasmarc.contains("[Theme]")
        && has_line(plasmarc, "name=org.kde.breeze")
        && fs::read(root + "/.config/ksmserverrc")? == "[General]\nloginMode=emptySession\n"
        && fs::read(root + "/.local/share/color-schemes/ConfigWeave.colors")? == "[General]\nName=ConfigWeave\n"
        && fs::read(root + "/.local/share/plasma/desktoptheme/config-weave/metadata.json")? == "{}\n"
        && fs::read(root + "/.config/autostart/config-weave-test.desktop")?.contains("Name=Config Weave Test")
    )
}

