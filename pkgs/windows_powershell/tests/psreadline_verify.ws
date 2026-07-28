use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let profile = "/cwhome2/.config/powershell/Microsoft.PowerShell_profile.ps1"
    if !fs::is_file(profile) { return Err("no profile was written") }
    let text = fs::read(profile)?

    // Symbols reached PowerShell in its own spelling, not WCL's.
    if !text.contains("Set-PSReadLineOption -EditMode Emacs") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -PredictionSource HistoryAndPlugin") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -PredictionViewStyle ListView") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -HistorySaveStyle SaveIncrementally") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -BellStyle None") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -MaximumHistoryCount 8192") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -HistoryNoDuplicates:$true") { return Ok(false) }
    if !text.contains("-Colors @{{ 'Command' = '#8181f7'; 'Parameter' = '#77dd77' }}") { return Ok(false) }
    if !text.contains("Set-PSReadLineKeyHandler -Chord 'UpArrow' -Function 'HistorySearchBackward'") { return Ok(false) }
    if !text.contains("Set-PSReadLineKeyHandler -Chord 'Ctrl+d,Ctrl+c' -ScriptBlock {{") { return Ok(false) }
    // Unset options must not appear at all.
    if text.contains("-ViModeIndicator") { return Err("an :unmanaged option was written anyway") }
    if text.contains("-DingTone") { return Err("an unset integer option was written anyway") }

    let out = shell::run("pwsh -NoProfile -NonInteractive -Command " + "\"$null = [ScriptBlock]::Create((Get-Content -Raw '" + profile + "'))\"", Value::Null)?
    if !out.success { return Err("the generated PSReadLine block does not parse: " + out.stderr.trim()) }
    Ok(true)
}
