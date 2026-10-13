use value
use sections

// The keys of git's `color` section; the rest lives in lib/sections.ws.

fn section() -> string { "color" }

// Every colour switch but color.pager (a plain boolean) takes the same set.
fn keys() -> List[string] {
    ["ui", "branch", "diff", "status", "grep", "interactive", "push",
     "remote", "showBranch", "advice", "transport", "pager"]
}

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
