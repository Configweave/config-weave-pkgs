# Claude Code Content File Formats

Research on the exact file formats for subagents, slash commands, skills, and memory files in Claude Code. **Claude Code version: latest (as of August 2026, model Haiku 4.5)**. Findings based on real examples from `~/.claude/plugins/` and `~/.claude/projects/` on this machine.

---

## Subagents (`.claude/agents/*.md`)

### Frontmatter Schema

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `name` | string | ✓ | — | Agent identifier; matches filename (without `.md`). Lowercase letters and hyphens only. |
| `description` | string | ✓ | — | Brief description of agent's purpose; tells Claude when to delegate to this agent |
| `tools` | string (comma-separated) | ✗ | Full default toolset | Tool names available to this agent, e.g., `Glob, Grep, Read, Write, Bash, WebFetch`. Omit to inherit all available tools. |
| `model` | string | ✗ | `inherit` | Claude model: `haiku`, `sonnet`, `opus`, `inherit`, or optionally with `[1m]` suffix for 1M token context, e.g., `sonnet[1m]`. Omit to inherit parent session's model. |
| `color` | string | ✗ | — | Visual indicator: `green`, `yellow`, `red`, `cyan`, `pink`, etc. (lowercase); only used when agent spawned in plugin UI |
| `disallowedTools` | string (comma-separated) | ✗ | — | Tools to remove from inherited set (rarely used) |
| `permissionMode` | string | ✗ | inherit | Permission mode: `acceptEdits`, `bypassPermissions`, `plan`, etc.; inherits from parent if omitted |
| `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `effort`, `isolation`, `initialPrompt` | various | ✗ | — | Advanced configuration fields; see official docs for details |

### File Naming

- **File path:** `.claude/agents/<name>.md` (user-level) or `.claude/agents/<name>.md` (project-level)
- **Name mapping:** Filename (minus `.md` extension) becomes the agent name
- **Scoping:** Can exist at both user-level (`~/.claude/agents/`) and project-level (`.claude/agents/`)
- **Priority:** Unknown; assume project-level agents shadow user-level if same name

### Example

```yaml
---
name: code-architect
description: Designs feature architectures by analyzing existing codebase patterns and conventions
tools: Glob, Grep, LS, Read, NotebookRead, WebFetch, WebSearch, Bash
model: sonnet
color: green
---

[Body text describing agent behavior...]
```

### Validation Behavior

- **Unknown fields:** Ignored (not validated as errors)
- **Missing required fields:** Uncertain—CLI likely refuses to load the agent if `name`, `description`, `tools`, or `model` are absent
- **Tools list:** Whitelist is checked at invocation; tool not in list means permission needed

---

## Slash Commands

Two formats exist; both are supported identically:

### Format A: Legacy `.claude/commands/<name>.md`

**Frontmatter:**

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `description` | string | ✓ | — | Short description shown in `/help` |
| `argument-hint` | string | ✗ | — | Argument syntax hint, e.g., `[skill-name]`, `<required-arg> [optional-arg]`, `<source-dir>` |
| `allowed-tools` | string \| array | ✗ | — | Pre-approved tools: `[Read, Write, Bash]` or `Read, Write, Bash` (both formats seen) |
| `name` | string | ✗ | filename | Explicit command name; overrides filename |
| `model` | string | ✗ | — | Model override: `haiku`, `sonnet`, `opus` |

**File naming:**
- Path: `.claude/commands/<name>.md`
- Command invoked as: `/<name>` (or `/name` derived from filename if `name:` not in frontmatter)

**Example:**

```yaml
---
description: Set up the Asana V2 MCP server connection
argument-hint: "[client_id]"
---

The user wants to connect Claude Code to Asana...
```

### Format B: Skill-style `.claude/skills/<name>/SKILL.md`

Commands can also be defined as skills in a directory structure (see Skills section). Frontmatter for commands in this format is identical to Format A, except:
- **File path:** `.claude/skills/<name>/SKILL.md`
- **Command name:** Derived from directory name (`<name>`)
- **user-invocable:** Should be set to `true` if command is to be callable via `/`

### Argument Handling

- Arguments are made available to the command body via **`$ARGUMENTS`** variable
- Positional syntax in `argument-hint`: `<arg1> [arg2]` describes but doesn't enforce
- No built-in argument validation or parsing; commands must parse `$ARGUMENTS` themselves

### Validation Behavior

- **Unknown fields:** Ignored
- **Missing description:** Uncertain—likely required for CLI `help` output
- **allowed-tools format:** Both comma-separated strings and YAML arrays are accepted

---

## Skills (`.claude/skills/<name>/SKILL.md`)

### Frontmatter Schema

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `name` | string | ✓ | — | Skill identifier; conventionally matches directory name |
| `description` | string | ✓ | — | **Trigger condition text**—tells Claude when to invoke the skill. Include phrases like "This skill should be used when the user asks to 'X', 'Y', or mentions 'Z'" |
| `version` | string | ✗ | — | Semantic version, e.g., `1.0.0` or `0.2.0` |
| `license` | string | ✗ | — | License info or reference, e.g., `"Complete terms in LICENSE.txt"` |
| `user-invocable` | boolean | ✗ | `false` | If `true`, skill can be called via `/name` slash command |
| `allowed-tools` | array \| string | ✗ | — | Pre-approved tools for this skill: `[Read, Write, Bash]` or `Read, Write, Bash` |

### Directory Structure

**Required:**
```
skills/
└── skill-name/
    └── SKILL.md          # Frontmatter + skill content
```

**Optional (no naming convention):**
```
skills/
└── skill-name/
    ├── SKILL.md
    ├── README.md         # Additional documentation
    ├── UPDATES.md        # Instructions for updating reference files (if this is a living skill)
    ├── references/       # Supporting documentation
    │   └── patterns.md
    ├── examples/         # Example files
    │   └── sample.md
    └── scripts/          # Helper scripts
        └── helper.sh
```

### Scoping

- **User-level:** `~/.claude/skills/<name>/SKILL.md`
- **Project-level:** `.claude/skills/<name>/SKILL.md`
- **Loaded by:** Marketplace name and scope; invoked by name when trigger description matches

### Validation Behavior

- **Unknown fields:** Ignored
- **Skill name derivation:** From `name:` field; directory name is for organization only
- **Description parsing:** Claude parses the description text to decide when to activate; no formal schema for trigger conditions

---

## CLAUDE.md: Project Context & Instructions

`CLAUDE.md` is the primary mechanism for storing project context at **multiple levels**. It is a plain-text markdown file with no frontmatter.

### File Locations & Discovery Order

Claude Code **combines multiple CLAUDE.md files** (does NOT stop at first found). Discovery order from filesystem root downward to working directory:

1. **Managed policy (org/enterprise):**
   - macOS: `/Library/Application Support/ClaudeCode/CLAUDE.md`
   - Linux/WSL: `/etc/claude-code/CLAUDE.md`
   - Windows: `C:\Program Files\ClaudeCode\CLAUDE.md`
   - **Cannot be excluded** by users

2. **User-level:** `~/.claude/CLAUDE.md` (personal preferences; applies to all projects)

3. **Directory traversal upward:** Parent directories walked up to find CLAUDE.md files
   - Example: In project `foo/bar/`, loads `foo/CLAUDE.md` first, then `foo/bar/CLAUDE.md`

4. **Project root:** `./CLAUDE.md` **OR** `./.claude/CLAUDE.md` (both locations valid; either will be loaded)

5. **Local personal overrides:** `./CLAUDE.local.md` (appended after main CLAUDE.md at same directory level)

6. **Subdirectories:** CLAUDE.md files in subdirectories load on-demand when Claude reads files in those directories

### Loading & Combining Behavior

**All discovered files are concatenated into a single context**, ordered from filesystem root to working directory:

```
[Managed policy content]
[User ~/.claude/CLAUDE.md]
[Parent dir foo/CLAUDE.md]
[Project root ./CLAUDE.md or ./.claude/CLAUDE.md]
[Project root ./CLAUDE.local.md]
[Subdirectory content as needed]
```

- **CLAUDE.local.md:** Appended after main CLAUDE.md at same directory level; add to `.gitignore`
- **Cross-file imports:** `@path/to/file` imports can reference content from other loaded files (all files load at startup)
- **Conflict handling:** If two rules contradict, Claude may pick arbitrarily; review for conflicts
- **Context cost:** All files consume tokens; use `.claude/rules/` for path-scoped rules to load only when matching files accessed
- **Exclusion:** Managed policy CLAUDE.md cannot be excluded; user/project CLAUDE.md can be excluded via `claudeMdExcludes` setting

### Format

**No frontmatter.** CLAUDE.md is plain markdown with optional `@` imports:

```markdown
# Project Context

This project is a Config Weave package library.

@docs/conventions.md

See also @.github/CONTRIBUTING.md for workflow.

## Team Guidelines

@team-standards.md
```

### `@` Import Syntax

**Basic syntax:** `@path/to/file`

**Behavior:**
- **Where to use:** Can appear anywhere in CLAUDE.md (inline or on its own line)
- **Paths:** Both relative and absolute paths supported
- **Resolution:** Relative paths resolve relative to the directory containing CLAUDE.md (not working directory)
- **To mention `@` literally** (without importing): Wrap in backticks: `` `@README` ``

**Example:**

```markdown
# Instructions

For setup, see @SETUP.md

Deploy via @scripts/deploy.sh (for reference only)
```

**Importing behavior:**
- The referenced file's content replaces the `@path` marker
- Works for `.md` and other text files
- Recursive: imported files can import other files
- **Maximum depth: 4 hops** (import depth limit to prevent infinite loops)

**HTML comments:**
- Block-level HTML comments (`<!-- comment -->`) are **stripped** before content reaches Claude's context
- **Do NOT consume context tokens** (they are removed at load time)
- Comments **inside fenced code blocks** are **preserved** (not stripped)
- When you use the Read tool to read the file directly, HTML comments remain visible (they are only stripped in Claude's context load)

**Marked blocks and edits:**
- Use `<!-- BEGIN config-weave: <name> -->` and `<!-- END config-weave: <name> -->` to mark regions for programmatic editing
- The HTML comment delimiters themselves are stripped from Claude's context
- The content between the markers IS included in Claude's context
- Package tools can edit within marked blocks without affecting Claude's use of CLAUDE.md
- Read tool sees comments; Claude's context does not

**Design implication for packages:** Because CLAUDE.md files from multiple levels combine into one context, a resource owning a marked block must specify which file it is editing. Options:
- Edit `./CLAUDE.md` (project-level, shared by team)
- Edit `./CLAUDE.local.md` (project-level personal override)
- Edit a file in parent directory (for shared team instructions)
- Document which file is target so playbook authors know which `.gitignore` entries to add

### AGENTS.md (Legacy)

**Status:** Legacy name from other systems; Claude Code does **not** read `AGENTS.md` automatically.

**How to unify with CLAUDE.md:**
- Create or edit `./CLAUDE.md` with `@AGENTS.md` import at the top:
  ```markdown
  @AGENTS.md
  
  ## Claude Code-Specific Instructions
  [additional content]
  ```
  This way both files' content appears in Claude's context in order.

- Alternative: Symlink `AGENTS.md` → `CLAUDE.md` on Unix-like systems

**Migration:** The `/init` command can detect and incorporate relevant sections from existing `AGENTS.md`, `.devin/rules/`, `.cursor/rules/`, etc., to bootstrap or update `CLAUDE.md`.

### Validation Behavior

- **Format:** Plain markdown; no frontmatter validation
- **File discovery:** Multiple files at different levels are loaded; if both `./CLAUDE.md` and `./.claude/CLAUDE.md` exist at project root, both are loaded
- **Import paths:** If a path doesn't exist, behavior is uncertain (test in practice; may fail silently or error)
- **Import depth:** Enforced limit of 4 hops; deeper imports fail
- **Cycle detection:** Circular imports likely detected and prevented; avoid creating them
- **External imports:** Require approval dialog on first encounter (user-level imports skip dialog for security)

---

## Scopes: User-Level vs. Project-Level

| Item | User-Level Path | Project-Level Path(s) | Combining Behavior |
|------|-----------------|----------------------|---|
| **Project context** | `~/.claude/CLAUDE.md` | `./CLAUDE.md` OR `./.claude/CLAUDE.md`<br/>(both valid) | **Combined**: All files concatenate<br/>root → working directory |
| **Personal overrides** | (none) | `./CLAUDE.local.md` (gitignored) | Appended after CLAUDE.md<br/>at same directory level |
| **Subagents** | `~/.claude/agents/*.md` | `.claude/agents/*.md` | Project-level preferred when<br/>same name exists; both loaded |
| **Slash commands** | `~/.claude/commands/*.md` | `.claude/commands/*.md` | Project-level preferred |
| **Skills** | `~/.claude/skills/<name>/SKILL.md` | `.claude/skills/<name>/SKILL.md` | Marketplace/scope determines;<br/>both loaded if available |
| **Directory rules** | (none) | `.claude/rules/**/*.md` | Path-scoped loading<br/>(on-demand per directory) |

**Notes:**
- **User-level** files are global across all projects
- **Project-level** files are local to that project only
- **CLAUDE.md combines, not overrides:** All discovered files merge into one context (crucial for design decisions)
- **Upward traversal:** Parent directories checked when walking up from working directory
- **Scoped references:** In plugins, scoping is `plugin-name:agent-name` or `plugin-name:command-name`

---

## Field Type Details

### `tools` Field (Subagents & Skills)

Format: Comma-separated string of tool names
```yaml
tools: Glob, Grep, LS, Read, NotebookRead, WebFetch, TodoWrite, WebSearch, KillShell, BashOutput
```

Known tool names include:
- Standard tools: `Read`, `Write`, `Edit`, `Glob`, `Grep`, `LS`, `Bash`, `WebFetch`, `WebSearch`
- Agent-specific: `TodoWrite`, `KillShell`, `BashOutput`, `NotebookRead`, `NotebookEdit`
- MCP tools: Variable based on installed MCP servers

### `allowed-tools` Field (Commands & Skills)

Format: String (comma-separated) or array of strings
```yaml
# Both are valid:
allowed-tools: Read, Write, Bash
allowed-tools: [Read, Write, Bash]

# Bash patterns:
allowed-tools: [Read, Edit, Write, Glob, Grep, WebFetch, WebSearch, "Bash(wc *)"]
```

Bash tool patterns allow filtering:
- `Bash(git checkout --branch:*)` — permit only git checkout with --branch flag
- `Bash(ls *)` — permit all ls invocations

### `model` Field

Format: Model ID with optional token context suffix
```yaml
model: haiku
model: sonnet
model: opus
model: sonnet[1m]    # Sonnet with 1M context tokens
model: opus[1m]      # Opus with 1M context tokens
```

---

## Frontmatter Validation

### Behavior on Malformed Fields

**Current behavior** (observed from real examples):
- **Unknown fields:** Silently ignored; no warning or error
- **Empty required fields:** Uncertain; examples show all required fields always present
- **Invalid field types:** Uncertain; examples show consistent types (string fields are strings, arrays are arrays)

**Recommendation for resource generation:**
- Validate frontmatter against the schemas above before writing
- Omit optional fields that have no value
- Use YAML type coercion to ensure correct types (e.g., boolean values without quotes)

---

## Special Cases & Uncertainties

### Uncertain Behaviors

1. **Argument parsing:** Are `argument-hint` constraints enforced, or just hints? **Assumption:** Hints only; commands must parse `$ARGUMENTS` themselves (no built-in validation).

2. **Import path errors:** What happens if an `@path/to/file` in CLAUDE.md doesn't exist? **Uncertain:** May fail silently or raise an error; test in practice.

3. **Subdirectory CLAUDE.md load timing:** Are subdirectory CLAUDE.md files loaded at startup or on-demand? **Confirmed:** On-demand when Claude reads files in that directory (not at launch).

4. **Worktree CLAUDE.local.md behavior:** Does each worktree have its own `.CLAUDE.local.md`, or is it shared? **Confirmed:** Each worktree has its own (because it's gitignored).

5. **Conflict resolution:** If two CLAUDE.md files have contradicting instructions, which takes precedence? **Confirmed:** Claude may pick arbitrarily; review regularly for conflicts.

### Key Corrections & Clarifications

- **Agent `tools` and `model` fields:** Both are **optional**, not required. If omitted, `tools` inherits the full default toolset, and `model` inherits the parent session's model (or explicitly use `model: inherit`).

- **CLAUDE.md path:** Located at **project root `./CLAUDE.md`** (NOT `.claude/CLAUDE.md`). Also valid: `./.claude/CLAUDE.md` at project root. Both locations load if both exist.

- **CLAUDE.md files COMBINE, not override:** Multiple CLAUDE.md files from managed policy, user-level, parent directories, and project root all concatenate into one context. This is critical for resource design: a package owning a marked block must declare which file it edits.

- **CLAUDE.md `@` imports:** Officially supported with confirmed 4-level maximum depth. HTML comment delimiters are stripped from Claude's context but visible when reading the file directly.

- **CLAUDE.local.md:** Project-level personal override file (gitignored); loaded and appended after main CLAUDE.md. Each worktree has its own.

- **AGENTS.md:** Legacy name; not automatically loaded. Use `@AGENTS.md` import inside CLAUDE.md to unify.

- **Skills directory structure:** The `skills/<name>/SKILL.md` format is standard; legacy `commands/*.md` format still works.

- **allowed-tools format:** Both comma-separated strings and YAML arrays accepted.

---

## Summary Table

| Type | Main File(s) | Frontmatter Fields | Required Fields | Key Note |
|------|-----------|-------------------|-----------------|----------|
| **Subagent** | `.claude/agents/<name>.md` | name, description, tools, model, color, disallowedTools, permissionMode, (others) | name, description | tools and model are optional (inherit if omitted) |
| **Slash Command** | `.claude/commands/<name>.md` | description, argument-hint, allowed-tools, name, model | description | Can be defined as skill; arguments via `$ARGUMENTS` |
| **Skill** | `.claude/skills/<name>/SKILL.md` | name, description, version, license, user-invocable, allowed-tools | name, description | Description is trigger conditions; tells Claude when to activate |
| **CLAUDE.md** | `./CLAUDE.md` OR `./.claude/CLAUDE.md` OR `~/.claude/CLAUDE.md` | (no frontmatter; plain markdown) | (n/a) | **Files combine** (not override); supports `@path/to/file` imports (4-level max); comments stripped from context |
| **CLAUDE.local.md** | `./CLAUDE.local.md` | (no frontmatter; plain markdown) | (n/a) | Personal project overrides; gitignored; appended after main CLAUDE.md |

---

## Recommendations for Resource Generation

For the `claude_code` package (to manage these resources):

1. **Validate frontmatter:** 
   - Agents: require `name` and `description`; `tools` and `model` are optional
   - Commands/Skills: require `description` (and `name` for skills)
   - CLAUDE.md: no frontmatter at all (plain markdown)

2. **Type coercion:** Ensure YAML types match expectations (booleans, strings, arrays)

3. **Whitespace:** Follow observed conventions (no trailing spaces, single space after `:` in frontmatter)

4. **Agent inheritance:** 
   - Omit `tools` to inherit full default toolset
   - Use `model: inherit` explicitly, or omit to inherit parent session's model

5. **CLAUDE.md files combine, not override:**
   - ALL discovered CLAUDE.md files (managed policy, user, parent dirs, project) are concatenated
   - Loading order: filesystem root → working directory
   - This is critical: a resource owning a marked block must declare which file it edits
   - Cross-file imports work because all files load at startup

6. **CLAUDE.md marked blocks:**
   - Use HTML comments: `<!-- BEGIN config-weave: <name> -->` and `<!-- END config-weave: <name> -->`
   - Content between markers is included in Claude's context (not stripped)
   - Comment delimiters themselves are stripped before reaching Claude
   - Package can safely edit within marked regions
   - Specify the target file: `./CLAUDE.md` (shared) or `./CLAUDE.local.md` (personal)
   - Read tool shows comments; Claude's context does not

7. **CLAUDE.md imports:**
   - Use `@path/to/file` for imports (no quotes needed)
   - Wrap in backticks to mention a path literally: `` `@README` ``
   - Confirmed maximum: **4-level import depth**
   - Imports skip markdown code spans and fenced blocks
   - Can reference content from other loaded CLAUDE.md files (all files load at startup)

7. **Skill descriptions:** Write descriptions as trigger conditions—focus on "when to use" not "what it does"

8. **File paths:** Respect user-level vs. project-level scoping; document precedence (project-level typically overrides user-level)

