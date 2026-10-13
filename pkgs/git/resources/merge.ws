use value
use sections

// The keys of git's `merge` section; the rest lives in lib/sections.ws.

fn section() -> string { "merge" }

fn keys() -> List[string] {
    ["tool", "guitool", "conflictStyle", "ff", "autoStash", "renames",
     "renameLimit", "renormalize", "log", "stat", "verbosity",
     "defaultToUpstream", "directoryRenames", "verifySignatures"]
}

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
