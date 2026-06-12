use value
use fs

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") { if l == line { return true } }
    false
}

fn verify(facts: Value) -> Result[bool, string] {
    let root = "/tmp/cw-tmux-home"
    let exact = fs::read(root + "/.tmux.conf")?
    let conf = fs::read(root + "/.config/tmux/tmux.conf")?
    Ok(
        exact == "set -g default-terminal tmux-256color\n"
        && has_line(conf, "set -g history-limit 50000")
        && has_line(conf, "setw -g mode-keys vi")
        && has_line(conf, "bind-key r source-file ~/.tmux.conf \\; display-message reloaded")
        && has_line(conf, "set -g @plugin 'tmux-plugins/tpm'")
        && fs::read(root + "/.config/tmuxinator/work.yml")? == "name: work\nroot: ~/src\nwindows: []\n"
        && fs::read(root + "/.teamocil/work.yml")? == "windows:\n  - name: shell\n"
    )
}
