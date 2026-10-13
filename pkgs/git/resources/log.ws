use value
use sections

// The keys of git's `log` section; the rest lives in lib/sections.ws.

fn section() -> string { "log" }

fn keys() -> List[string] {
    ["date", "decorate", "follow", "abbrevCommit", "showSignature", "mailmap",
     "graphColors", "diffMerges", "showRoot"]
}

fn hyphenated() -> List[string] { ["diffMerges"] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
