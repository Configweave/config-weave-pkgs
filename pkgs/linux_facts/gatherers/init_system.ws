use value
use fs
use path

fn trim_read(p: string) -> string { fs::read(p).unwrap_or("").trim() }

// The init system is whatever PID 1 is. /proc/1/comm is readable by
// anyone; /proc/1/exe (root only) names the real binary behind an "init".
// Tools merely being installed (systemctl, service, /etc/runit) say
// nothing: Debian ships `service` everywhere, and a container has a
// package's files without its daemon.
//
// The bare token, without a leading colon: `:systemd` is a WCL *source*
// spelling, and the engine promotes a symbol-typed `returns` key into a real
// WCL symbol on the way into the variable space.
fn detect() -> string {
    let comm = trim_read("/proc/1/comm")
    let exe = path::filename(fs::read_link("/proc/1/exe").unwrap_or(""))
    if comm == "systemd" || exe == "systemd" { return "systemd" }
    // OpenRC runs under its own openrc-init, or under sysvinit's or
    // busybox's init; /run/openrc exists only once it has booted.
    if comm == "openrc-init" || fs::is_dir("/run/openrc") { return "openrc" }
    if comm == "runit" || comm == "runit-init" || exe == "runit" || exe == "runit-init" { return "runit" }
    // sysvinit's PID 1 is an `init` reading /etc/inittab. busybox init reads
    // one too, so its binary is excluded by name.
    if comm == "init" && exe != "busybox" && fs::is_file("/etc/inittab") { return "sysvinit" }
    "unknown"
}

fn gather(params: Value) -> Value {
    Value::Map(#{
        "init": Value::String(detect())
    })
}
