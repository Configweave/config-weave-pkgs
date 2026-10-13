use value
use sections

// The keys of git's `fetch` section; the rest lives in lib/sections.ws.

fn section() -> string { "fetch" }

fn keys() -> List[string] {
    ["prune", "pruneTags", "parallel", "recurseSubmodules", "all", "output",
     "showForcedUpdates", "writeCommitGraph", "negotiationAlgorithm",
     "fsckObjects", "unpackLimit"]
}

fn hyphenated() -> List[string] { ["recurseSubmodules"] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
