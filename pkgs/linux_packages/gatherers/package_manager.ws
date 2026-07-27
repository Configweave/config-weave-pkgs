use value
use fs

fn exists_bin(path: string) -> bool {
    fs::exists(path)
}

// The bare token, without a leading colon: `:apt` is a WCL *source* spelling,
// and the engine promotes a symbol-typed `returns` key into a real WCL symbol
// on the way into the variable space.
//
// Order matters. The system managers come first, so a Debian host running
// flatpak still reports :apt; the ecosystem managers below only win when no
// system manager was found. Detection is independent of what this library can
// manage — :snap and :nix are reported with no package behind them.
fn gather(params: Value) -> Value {
    let manager = if exists_bin("/usr/bin/apt-get") {
        "apt"
    } else if exists_bin("/usr/bin/dnf5") {
        "dnf5"
    } else if exists_bin("/usr/bin/dnf") {
        "dnf"
    } else if exists_bin("/usr/bin/microdnf") {
        "microdnf"
    } else if exists_bin("/usr/bin/yum") {
        "yum"
    } else if exists_bin("/usr/bin/tdnf") {
        "tdnf"
    } else if exists_bin("/usr/bin/zypper") {
        "zypper"
    } else if exists_bin("/usr/bin/pacman") {
        "pacman"
    } else if exists_bin("/sbin/apk") || exists_bin("/usr/sbin/apk") {
        "apk"
    } else if exists_bin("/usr/bin/xbps-install") {
        "xbps"
    } else if exists_bin("/usr/bin/emerge") {
        "emerge"
    } else if exists_bin("/usr/bin/eopkg") {
        "eopkg"
    } else if exists_bin("/usr/bin/swupd") {
        "swupd"
    } else if exists_bin("/usr/sbin/urpmi") || exists_bin("/usr/bin/urpmi") {
        "urpmi"
    } else if exists_bin("/usr/sbin/slackpkg") || exists_bin("/usr/bin/slackpkg") {
        "slackpkg"
    } else if exists_bin("/usr/bin/opkg") || exists_bin("/bin/opkg") {
        "opkg"
    } else if exists_bin("/usr/bin/rpm-ostree") {
        "rpm-ostree"
    } else if exists_bin("/usr/bin/flatpak") {
        "flatpak"
    } else if exists_bin("/usr/bin/snap") {
        "snap"
    } else if exists_bin("/usr/bin/nix-env") {
        "nix"
    } else if exists_bin("/usr/bin/guix") {
        "guix"
    } else {
        "unknown"
    }
    Value::Map(#{
        "manager": Value::String(manager),
        "known": Value::Bool(manager != "unknown")
    })
}
