use value
use sections

// The keys of git's `rebase` section; the rest lives in lib/sections.ws.

fn section() -> string { "rebase" }

fn keys() -> List[string] {
    ["autoSquash", "autoStash", "backend", "forkPoint", "rebaseMerges",
     "updateRefs", "stat", "abbreviateCommands", "instructionFormat",
     "missingCommitsCheck", "rescheduleFailedExec"]
}

fn hyphenated() -> List[string] { ["rebaseMerges"] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
