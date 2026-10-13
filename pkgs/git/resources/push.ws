use value
use sections

// The keys of git's `push` section; the rest lives in lib/sections.ws.

fn section() -> string { "push" }

fn keys() -> List[string] {
    ["default", "autoSetupRemote", "followTags", "gpgSign",
     "recurseSubmodules", "useForceIfIncludes", "negotiate"]
}

fn hyphenated() -> List[string] { ["gpgSign", "recurseSubmodules"] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
