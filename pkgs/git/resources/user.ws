use value
use sections

// The keys of git's `user` section; the rest lives in lib/sections.ws.

fn section() -> string { "user" }

fn keys() -> List[string] { ["name", "email", "signingKey", "useConfigOnly"] }

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
