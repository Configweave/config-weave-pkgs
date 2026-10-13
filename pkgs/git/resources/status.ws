use value
use sections

// The keys of git's `status` section; the rest lives in lib/sections.ws.

fn section() -> string { "status" }

fn keys() -> List[string] {
    ["short", "branch", "showStash", "showUntrackedFiles", "submoduleSummary",
     "aheadBehind", "relativePaths", "renames", "renameLimit",
     "displayCommentPrefix"]
}

fn hyphenated() -> List[string] { [] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
