use value
use common

// The preference name is spliced into the script as a parameter name, so it
// must look like one.
fn pref_name(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    for c in name.chars() {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
        if !ok { return Err("invalid 'name' value '" + name + "' (expected a Set-MpPreference parameter name such as ScanScheduleDay)") }
    }
    // These come in pairs (an id list and an action list matched by
    // position), which one name/value cannot express.
    for suffix in ["_Ids", "_Actions", "_RuleSpecificExclusions", "_RuleSpecificExclusions_Id"] {
        if name.ends_with(suffix) { return Err("'" + name + "' is one half of a paired preference, which this resource cannot set") }
    }
    Ok(name)
}

// PowerShell that resolves the preference and converts the wanted value to
// the parameter's own type, binding:
//   $t     the Set-MpPreference parameter type
//   $want  the value converted to $t (an array for array types)
//   $same  whether the current value already equals it
//
// Values are compared in a canonical form of their type, because
// Get-MpPreference does not report them the way Set-MpPreference takes
// them: enums come back as bytes, times of day as TimeSpans, and a
// preference can only be checked when Get-MpPreference reports it at all.
fn resolve_ps(name: string, value: string) -> string {
    "$name = " + common::ps_q(name) + "; $value = " + common::ps_q(value) + "; " +
    "$param = (Get-Command Set-MpPreference).Parameters[$name]; " +
    "$notPrefs = @('Force', 'CimSession', 'ThrottleLimit', 'AsJob') + [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters; " +
    "if ($null -eq $param -or $notPrefs -contains $name) {{ throw ('Set-MpPreference has no preference parameter named ' + $name) }}; " +
    "$prop = (Get-MpPreference).PSObject.Properties[$name]; " +
    "if ($null -eq $prop) {{ throw ('Get-MpPreference does not report ' + $name + ', so its value cannot be checked') }}; " +
    "$t = $param.ParameterType; " +
    "function Conv($et, [string]$s) {{ " +
    "$s = $s.Trim(); " +
    "if ($et -eq [bool]) {{ " +
    "if ($s -match '^(\\$?true|1)$') {{ return $true }}; if ($s -match '^(\\$?false|0)$') {{ return $false }}; " +
    "throw ('''' + $s + ''' is not a boolean (true or false)') }}; " +
    "if ($et.IsEnum) {{ return [Enum]::Parse($et, $s, $true) }}; " +
    "if ($et -eq [datetime]) {{ return [datetime]::Today.Add([TimeSpan]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)) }}; " +
    "[System.Management.Automation.LanguagePrimitives]::ConvertTo($s, $et, [Globalization.CultureInfo]::InvariantCulture) }}; " +
    "function Canon($v) {{ " +
    "if ($null -eq $v) {{ return '' }}; " +
    "if ($v -is [datetime]) {{ return $v.TimeOfDay.ToString() }}; " +
    "if ($v -is [timespan]) {{ return $v.ToString() }}; " +
    "if ($v -is [bool]) {{ return $v.ToString() }}; " +
    "if ($v -is [enum]) {{ return ([int64]$v).ToString() }}; " +
    "if ($v -is [ValueType]) {{ return ([decimal]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }}; " +
    "[string]$v }}; " +
    "if ($t.IsArray) {{ " +
    "$et = $t.GetElementType(); " +
    "$want = @($value.Split(',') | ForEach-Object {{ $_.Trim() }} | Where-Object {{ $_ -ne '' }} | ForEach-Object {{ Conv $et $_ }}); " +
    "$cur = @(@($prop.Value) | Where-Object {{ $null -ne $_ }}); " +
    "$a = (@($want | ForEach-Object {{ Canon $_ }}) | Sort-Object -Unique) -join [char]10; " +
    "$b = (@($cur | ForEach-Object {{ Canon $_ }}) | Sort-Object -Unique) -join [char]10; " +
    "$same = ($a -eq $b) }} else {{ " +
    "$want = Conv $t $value; $cur = $prop.Value; " +
    "$same = ((Canon $want) -eq (Canon $cur)) }}; "
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = pref_name(params)?
    let value = common::param_str(params, "value", "")
    common::single_line("value", value)?
    let st = common::ps("reading Defender preference " + name,
        resolve_ps(name, value) + "if ($same) {{ 'MATCH' }} else {{ 'DIFF' }}")?
    if st == "MATCH" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = pref_name(params)?
    let value = common::param_str(params, "value", "")
    common::single_line("value", value)?
    // An array set to the empty list cannot be passed to Set-MpPreference,
    // so it is cleared with Remove-MpPreference instead: some lists take the
    // items to remove, others (ProxyBypass) a switch that clears them all.
    common::ps("setting Defender preference " + name,
        resolve_ps(name, value) +
        "if (-not $same) {{ " +
        "if ($t.IsArray -and $want.Count -eq 0) {{ " +
        "$rt = (Get-Command Remove-MpPreference).Parameters[$name].ParameterType; " +
        "$p = if ($rt -eq [switch]) {{ @{{ $name = $true }} }} else {{ @{{ $name = $cur }} }}; Remove-MpPreference @p }} " +
        "else {{ $p = @{{ $name = [System.Management.Automation.LanguagePrimitives]::ConvertTo($want, $t) }}; Set-MpPreference @p }} }}")?
    Ok(ApplyResult::Success)
}
