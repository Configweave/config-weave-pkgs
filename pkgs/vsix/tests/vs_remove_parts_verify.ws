use value
use fs
use common
use vs

fn community() -> Result[Value, string] {
    let found = vs::instances("Microsoft.VisualStudio.Product.Community", "[17.0,18.0)")?
    if found.is_empty() { return Err("vswhere finds no Visual Studio Community 2022") }
    Ok(found.get(0).unwrap())
}

fn versions(inst: Value, scope: string, id: string) -> Result[List[string], string] {
    Ok(vs::installed(inst, scope, id)?.map(|f| common::get_str(f, "version")))
}

fn verify(facts: Value) -> Result[bool, string] {
    let inst = community()?
    let outer = vs::installed(inst, "machine", "ConfigWeave.Test.Outer")?
    if outer.is_empty() { return Err("ConfigWeave.Test.Outer is not installed") }
    let dir = common::get_str(outer.get(0).unwrap(), "dir")
    if fs::exists(dir + "\\Shared\\Nested.vsix") { return Err("the nested package was installed with outer") }
    let manifest = fs::read(dir + "\\extension.vsixmanifest")?
    if manifest.contains("Location=") { return Err("the installed manifest still has a dependency Location") }
    if !manifest.contains("ConfigWeave.Test.Nested") { return Err("the dependency itself was dropped from the manifest") }
    // The nested 2.0 that was there before is untouched.
    let nested = versions(inst, "machine", "ConfigWeave.Test.Nested")?
    if nested.len() != 1 || !common::same_version(nested.get(0).unwrap(), "2.0") { return Err("ConfigWeave.Test.Nested is now " + nested.join(", ")) }
    // The stripped copy's manifest.json lists no removed part, and its
    // SHA-256 for the rewritten extension.vsixmanifest is the part's own.
    let copies = fs::glob("C:\\ProgramData\\config-weave\\vsix\\stripped\\*\\outer.vsix")?
    if copies.is_empty() { return Err("no stripped copy of outer.vsix in the cache") }
    let script = "Add-Type -AssemblyName WindowsBase\n" +
        "$p = [IO.Packaging.Package]::Open($env:CW_FILE, 'Open', 'Read')\n" +
        "try {{\n" +
        "  function U($n) {{ [IO.Packaging.PackUriHelper]::CreatePartUri([Uri]::new($n, [UriKind]::Relative)) }}\n" +
        "  if ($p.PartExists((U 'Shared/Nested.vsix'))) {{ throw 'the stripped copy still has Shared/Nested.vsix' }}\n" +
        "  $r = New-Object IO.StreamReader($p.GetPart((U 'manifest.json')).GetStream('Open', 'Read')); $j = $r.ReadToEnd() | ConvertFrom-Json; $r.Dispose()\n" +
        "  if (@($j.files | Where-Object {{ $_.fileName -eq '/Shared/Nested.vsix' }}).Count) {{ throw 'manifest.json still lists /Shared/Nested.vsix' }}\n" +
        "  $s = $p.GetPart((U 'extension.vsixmanifest')).GetStream('Open', 'Read')\n" +
        "  $h = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object {{ $_.ToString('X2') }}); $s.Dispose()\n" +
        "  $want = @($j.files | Where-Object {{ $_.fileName -eq '/extension.vsixmanifest' }})[0].sha256\n" +
        "  if ($want -ne $h) {{ throw ('manifest.json has ' + $want + ' for extension.vsixmanifest, the part hashes to ' + $h) }}\n" +
        "}} finally {{ $p.Close() }}\n"
    let out = common::run_ps(script, #{ "CW_FILE": Value::String(copies.get(0).unwrap()) }, 120)?
    if !out.success { return Err(common::failure("checking the stripped copy", out)) }
    Ok(true)
}
