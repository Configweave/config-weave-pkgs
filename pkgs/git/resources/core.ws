use value
use sections

// The keys of git's `core` section; the rest lives in lib/sections.ws.

fn section() -> string { "core" }

fn keys() -> List[string] {
    ["editor", "pager", "autocrlf", "eol", "safecrlf", "excludesFile",
     "attributesFile", "hooksPath", "sshCommand", "askPass", "fileMode",
     "ignoreCase", "symlinks", "precomposeUnicode", "quotePath",
     "preloadIndex", "commentChar", "whitespace", "abbrev", "compression",
     "bigFileThreshold", "fsmonitor", "untrackedCache", "logAllRefUpdates"]
}

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
