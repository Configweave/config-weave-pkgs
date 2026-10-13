use value
use sections

// The keys of git's `diff` section; the rest lives in lib/sections.ws.

fn section() -> string { "diff" }

fn keys() -> List[string] {
    ["tool", "guitool", "algorithm", "colorMoved", "colorMovedWs", "context",
     "interHunkContext", "renames", "renameLimit", "external",
     "indentHeuristic", "mnemonicPrefix", "noPrefix", "orderFile", "relative",
     "submodule", "wordRegex", "wsErrorHighlight", "dirstat",
     "statGraphWidth", "statNameWidth", "srcPrefix", "dstPrefix",
     "ignoreSubmodules", "trustExitCode"]
}

fn hyphenated() -> List[string] { ["colorMoved"] }

fn check(params: Value) -> Result[CheckResult, string] {
    sections::check(params, section(), keys(), hyphenated())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    sections::apply(params, section(), keys(), hyphenated())
}
