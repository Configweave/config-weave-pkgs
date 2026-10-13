use value
use fs

fn lines(p: string) -> Result[List[string], string] {
    let out = []
    for l in fs::read(p)?.split("\n") {
        let t = l.trim().replace("\t", " ")
        if t != "" && !t.starts_with("#") { out.push(t) }
    }
    Ok(out)
}

// fstab lines whose mount point (field 2) is mp
fn entries(ls: List[string], mp: string) -> List[string] {
    ls.filter(|l| l.split(" ").filter(|f| f != "").get(1).unwrap_or("") == mp)
}

fn verify(facts: Value) -> Result[bool, string] {
    let fstab = lines("/etc/fstab")?
    let mounts = lines("/proc/mounts")?
    let want = [
        ["/mnt/cw-test", "tmpfs /mnt/cw-test tmpfs defaults 0 0"],
        ["/mnt/cw\\040new", "tmpfs /mnt/cw\\040new tmpfs size=1m 0 0"],
        ["/mnt/cw-opts", "tmpfs /mnt/cw-opts tmpfs size=2m 0 0"],
        ["/mnt/cw-dup", "tmpfs /mnt/cw-dup tmpfs defaults 0 0"],
        ["/mnt/cw-unmounted", "tmpfs /mnt/cw-unmounted tmpfs defaults 0 0"],
    ]
    for w in want {
        let got = entries(fstab, w[0])
        if got.len() != 1 || got[0] != w[1] { return Err("fstab entries for " + w[0] + ": " + got.join(" | ")) }
    }
    for gone in ["/mnt/cw-seeded", "/mnt/cw-um", "/mnt/cw-bad"] {
        if !entries(fstab, gone).is_empty() { return Err("fstab still has " + gone) }
    }
    for m in ["/mnt/cw\\040new", "/mnt/cw-opts", "/mnt/cw-unmounted"] {
        if entries(mounts, m).is_empty() { return Err(m + " is not mounted") }
    }
    if entries(mounts, "/mnt/cw-test").len() != 0 { return Err("/mnt/cw-test was mounted with mount = false") }
    if !entries(mounts, "/mnt/cw-um").is_empty() { return Err("/mnt/cw-um is still mounted") }
    // the remount applied the new size: tmpfs reports size=2048k
    let opts = entries(mounts, "/mnt/cw-opts").get(0).unwrap_or("")
    if !opts.contains("size=2048k") { return Err("/mnt/cw-opts was not remounted with size=2m: " + opts) }
    Ok(true)
}
