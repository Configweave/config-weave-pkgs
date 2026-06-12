use value
use fs

fn exists_bin(path: string) -> bool {
    fs::exists(path)
}

fn gather(params: Value) -> Value {
    let manager = if exists_bin("/usr/bin/apt-get") {
        "apt"
    } else if exists_bin("/usr/bin/dnf") {
        "dnf"
    } else if exists_bin("/usr/bin/yum") {
        "yum"
    } else if exists_bin("/usr/bin/zypper") {
        "zypper"
    } else if exists_bin("/usr/bin/pacman") {
        "pacman"
    } else if exists_bin("/sbin/apk") || exists_bin("/usr/sbin/apk") {
        "apk"
    } else {
        "unknown"
    }
    Value::Map(#{
        "manager": Value::String(manager),
        "known": Value::Bool(manager != "unknown")
    })
}

