use value
use sections

// The keys of git's `commit` section; the rest lives in lib/sections.ws.

fn section() -> string { "commit" }

fn keys() -> List[string] { ["gpgSign", "cleanup", "status", "template", "verbose"] }

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
