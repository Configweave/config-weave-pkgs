use value
use sections

// The keys of git's `pull` section; the rest lives in lib/sections.ws.

fn section() -> string { "pull" }

fn keys() -> List[string] { ["rebase", "ff", "autoStash", "octopus", "twohead"] }

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
