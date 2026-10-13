use value
use fs

// Detection order, first match wins. Each entry is
// [symbol, guard, path, path, ...]: the manager is detected when the guard
// exists ("" for none) and any one of the paths does.
//
// rpm-ostree comes before the dnf family: Fedora Atomic ships dnf5 as
// well, but /run/ostree-booted says the running system is an image. The
// system managers come next, so a Debian host running flatpak still reports
// :apt; the ecosystem managers only win when no system manager was found.
// Nix and Guix need their store and an installed CLI. Detection is
// independent of what this library can manage: :snap and :nix are reported
// with no package behind them.
fn managers() -> List[List[string]] {
    [
        ["rpm_ostree", "/run/ostree-booted", "/usr/bin/rpm-ostree"],
        ["apt", "", "/usr/bin/apt-get"],
        ["dnf5", "", "/usr/bin/dnf5"],
        ["dnf", "", "/usr/bin/dnf"],
        ["microdnf", "", "/usr/bin/microdnf"],
        ["yum", "", "/usr/bin/yum"],
        ["tdnf", "", "/usr/bin/tdnf"],
        ["zypper", "", "/usr/bin/zypper"],
        ["pacman", "", "/usr/bin/pacman"],
        ["apk", "", "/sbin/apk", "/usr/sbin/apk", "/usr/bin/apk"],
        ["xbps", "", "/usr/bin/xbps-install"],
        ["emerge", "", "/usr/bin/emerge"],
        ["eopkg", "", "/usr/bin/eopkg"],
        ["swupd", "", "/usr/bin/swupd"],
        ["urpmi", "", "/usr/sbin/urpmi", "/usr/bin/urpmi"],
        ["slackpkg", "", "/usr/sbin/slackpkg", "/usr/bin/slackpkg"],
        ["opkg", "", "/usr/bin/opkg", "/bin/opkg"],
        ["flatpak", "", "/usr/bin/flatpak"],
        ["snap", "", "/usr/bin/snap"],
        ["nix", "/nix/store", "/run/current-system/sw/bin/nix-env", "/nix/var/nix/profiles/default/bin/nix-env", "/root/.nix-profile/bin/nix-env", "/usr/bin/nix-env", "/usr/local/bin/nix-env"],
        ["guix", "/gnu/store", "/run/current-system/profile/bin/guix", "/var/guix/profiles/per-user/root/current-guix/bin/guix", "/root/.config/guix/current/bin/guix", "/usr/bin/guix", "/usr/local/bin/guix"]
    ]
}

fn detected(entry: List[string]) -> bool {
    if entry[1] != "" && !fs::exists(entry[1]) { return false }
    for i in 2..entry.len() { if fs::exists(entry[i]) { return true } }
    false
}

// The bare token, without a leading colon: `:apt` is a WCL *source* spelling,
// and the engine promotes a symbol-typed `returns` key into a real WCL symbol
// on the way into the variable space.
fn gather(params: Value) -> Value {
    let manager = "unknown"
    for m in managers() {
        if detected(m) { manager = m[0]; break }
    }
    Value::Map(#{
        "manager": Value::String(manager),
        "known": Value::Bool(manager != "unknown")
    })
}
