use value
use sections

// The keys of git's `init` section; the rest lives in lib/sections.ws.

fn section() -> string { "init" }

fn keys() -> List[string] {
    ["defaultBranch", "templateDir", "defaultObjectFormat", "defaultRefFormat"]
}

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
