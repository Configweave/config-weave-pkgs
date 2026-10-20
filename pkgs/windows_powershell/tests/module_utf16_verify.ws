use value
use fs
use shell

fn utf16_bom(file: string) -> Result[bool, string] {
    let bytes = fs::read_bytes(file)?
    Ok(bytes.len() >= 2 && bytes[0] == 255 && bytes[1] == 254)
}

fn verify(facts: Value) -> Result[bool, string] {
    // The premise: Windows PowerShell 5.1 wrote the manifests as UTF-16LE.
    for n in ["CwUtf16", "CwUtf16Bad"] {
        let src = "C:\\cwsrc\\" + n + "\\" + n + ".psd1"
        if !utf16_bom(src)? { return Err(src + " is not UTF-16LE with a BOM, so the test proves nothing") }
    }
    let root = "C:\\Program Files\\WindowsPowerShell\\Modules"
    let installed = root + "\\CwUtf16\\3.2.1\\CwUtf16.psd1"
    if !fs::is_file(installed) { return Err("the module was not installed at " + installed) }
    if !utf16_bom(installed)? { return Err("the installed manifest is no longer UTF-16LE") }
    if fs::exists(root + "\\CwUtf16Bad") { return Err("a module whose UTF-16LE manifest contradicts its version was installed anyway") }
    // What Windows PowerShell itself sees.
    let out = shell::run("powershell -NoProfile -NonInteractive -Command \"@(Get-Module -ListAvailable -Name CwUtf16 | ForEach-Object {{ [string]$_.Version + ' ' + $_.ModuleBase }}) -join ';'\"", Value::Null)?
    if !out.success { return Err("Get-Module failed: " + out.stderr.trim()) }
    if out.stdout.trim() != "3.2.1 " + root + "\\CwUtf16\\3.2.1" { return Err("Get-Module -ListAvailable reports CwUtf16 as: " + out.stdout.trim()) }
    Ok(true)
}
