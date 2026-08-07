# Claude Code settings.json Surface Research

**Research Date:** 2026-08-07  
**System:** Linux (CachyOS)  
**Claude Code Version:** 2.1.224  
**Research Source:** Official Anthropic documentation + local CLI + file inspection

---

## Executive Summary

This document catalogs the complete Claude Code configuration surface for Linux:
- **65+ documented settings.json keys** organized by function
- **9-level configuration precedence chain** from defaults to in-session overrides
- **Complete directory layout** under `~/.claude/` and project `.claude/`
- **Command-valued setting contracts** for statusLine and apiKeyHelper
- **Managed settings system** for enterprise policy enforcement
- **Linux-specific file paths** for all configuration scopes

**Key Design Facts:**
- Settings files are declarative JSON (no comments)
- Permissions rules MERGE across scopes (don't override)
- Auto-mode classifier explicitly does NOT read `.claude/settings.local.json` (security)
- Most settings take effect immediately; a few require restart
- Managed settings can enforce policy; user/project settings cannot override policy

---

## Part 1: Configuration File Locations and Structure

### User Configuration Files

#### `~/.claude/settings.json` (User-level settings)
- **Purpose:** Declarative configuration applied to all Claude Code sessions
- **Scope:** Highest priority among non-managed settings
- **Format:** JSON object, no comments allowed
- **Persistence:** Checked-in via backups at `~/.claude/backups/`
- **Overridden by:** Project, project-local, CLI args, managed settings, in-session commands

#### `.claude/settings.json` (Project-level settings)
- **Purpose:** Configuration scoped to a single project/repository
- **Scope:** Overrides user settings for this project only
- **Format:** Identical to user settings.json
- **Recommended:** Check into version control
- **Overridden by:** `.claude/settings.local.json`, CLI args, managed settings, in-session commands

#### `.claude/settings.local.json` (Project local/machine-specific settings)
- **Purpose:** Machine-local overrides for development environment
- **Scope:** Not checked into version control (ignored by git-aware tools)
- **Recommended:** Add to .gitignore
- **Priority:** Highest among local files (except CLI args)
- **Important Security Note:** NOT read by auto-mode classifier (prevents injection via local overrides)

### Other User Configuration Directories

#### `~/.claude/agents/`
- Agent definition files (*.md with YAML frontmatter)
- Automatically loaded; available as `/agent-name` commands
- Define custom agents with custom system prompts, tool restrictions, etc.

#### `~/.claude/themes/`
- Custom output theme definitions (*.json)
- Loaded based on `outputStyle` setting

#### `~/.claude/keybindings.json` (if exists)
- Custom keyboard shortcut bindings
- JSON format: key binding → command/action mapping
- Not created by default; manually created for customization

#### `~/.claude/hooks/` (alternative to settings.json)
- Hook definitions as files instead of in settings.json
- Loaded automatically

#### `~/.claude/plugins/` (for project-specific plugins)
- Plugins that only activate in this project
- Alternative to global plugin installation

### System Configuration (Linux)

#### `/etc/claude-code/managed-settings.json`
- System-wide managed settings (enterprise MDM)
- Highest precedence for policy enforcement
- Deployed by system administrator

#### `/etc/claude-code/managed-settings.d/*.json`
- Modular managed settings files
- All files in directory are loaded and merged

### Runtime State Files (NOT declarative config)

#### `~/.claude.json` (PRIMARY STATE FILE)
- **Size:** 80–90 KB typically
- **Contents:**
  - Active and inactive session metadata
  - Conversation history and messages
  - Project state and worktree assignments
  - MCP server connections and state
  - Plugin installation and enablement state
  - UI state (sidebar positions, scroll positions, etc.)
  - CLAUDE.md discovery and caching
- **Important:** Primarily runtime state, not declarative configuration
- **Editing:** NOT intended for manual editing; automatically managed by Claude Code
- **Version Control:** Should NOT be checked in

#### `~/.claude.json.tmp.*`
- Temporary files during atomic writes of ~/.claude.json
- Cleaned up automatically
- Safe to delete if present

#### `~/.claude/.credentials.json` (encrypted)
- Stored authentication credentials
- Runtime state
- File permissions: 600 (user-only access)

#### `~/.claude/history.jsonl`
- Conversation history in JSONL format
- Searchable session history
- File permissions: 600 (user-only access)

---

## Part 2: Configuration Precedence Chain (Linux)

The complete precedence order for settings resolution:

| Priority | Source | Path(s) | Notes |
|----------|--------|---------|-------|
| 1 (lowest) | Built-in defaults | [hardcoded] | Last resort if nothing else set |
| 2 | Managed settings (cached) | `~/.claude/remote-settings.json` | Server-delivered, cached from api.anthropic.com |
| 3 | Managed settings (system) | `/etc/claude-code/` | Enterprise/MDM-deployed |
| 4 | Environment variables | `CLAUDE_*` prefixed | Checked at startup |
| 5 | User settings | `~/.claude/settings.json` | Applied to all sessions |
| 6 | Project settings | `.claude/settings.json` | Applied to sessions in this project |
| 7 | Project local settings | `.claude/settings.local.json` | Machine-specific overrides |
| 8 | CLI arguments | `--settings`, `--model`, etc. | Command-line flags |
| 9 (highest) | In-session commands | `/config`, `/model`, `/permissions` | Runtime overrides in active session |

**Special Rules:**

- **Permissions MERGE:** Permission rules from multiple scopes are merged together (combined), not replaced
- **Auto-mode classifier security:** The auto-mode classifier specifically does NOT read `.claude/settings.local.json`, preventing a locally-misconfigured settings file from bypassing permission checks
- **Env variable merging (v2.1.223+):** When both admin and user settings define env vars, they merge per-key (no longer block replacement)
- **Admin env withholding (v2.1.198+):** Server-managed proxy, TLS, and auth environment variables are withheld from the cached env until the server confirms them during startup (prevents man-in-the-middle attacks)

---

## Part 3: Complete settings.json Keys

All keys below follow the same format across user, project, local, and managed settings files (except where noted as "managed-only").

### A. Model Selection & Capability

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `model` | string | Model ID or alias | `"claude-opus-4-1"` (account-dependent) | Active model (e.g., `"opus"`, `"opus[1m]"`, `"claude-opus-5"`); defaults to `claude-opus-4-1` for standard accounts, organization default for Team/Enterprise |
| `availableModels` | object | `{ "modelId": true\|false, ... }` | [all Anthropic models] | Which models appear in `/model` picker |
| `modelOverrides` | object | Per-provider model substitutions | {} | Map models to alternatives (e.g., redirect Opus → Claude 3 for Bedrock) |
| `effortLevel` | string | `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"` | `"medium"` | Thinking/reasoning effort; higher = more tokens |
| `alwaysThinkingEnabled` | boolean | `true` \| `false` | `false` | Enable thinking by default in all sessions |
| `fallbackModel` | string | Model ID | [none] | Model to use if primary is overloaded (CLI only with `--print`) |

### B. Context & Memory Management

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `autoCompactEnabled` | boolean | `true` \| `false` | `false` | Automatically compact context when approaching limit |
| `autoCompactWindow` | string | `"auto"` or token count (`"100k"`, `"200k"`, ..., `"1000k"`) | `"auto"` | Target window size for auto-compact |
| `autoMemoryEnabled` | boolean | `true` \| `false` | `false` | Auto-save conversation summaries to memory |
| `awaySummaryEnabled` | boolean | `true` \| `false` | `true` | Create summaries when session goes idle |
| `awaySummaryInterval` | number | Minutes | 30 | How long idle before creating summary |

### C. Permissions & Security

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `permissions` | object | `{ "allow": [...], "deny": [...], "ask": [...], "defaultMode": "...", "additionalDirectories": [...], "disableAutoMode": "...", "disableBypassPermissionsMode": "..." }` | Allow everything | Tool access control rules (all arrays merge across scopes) |
| `autoMode` | object | `{ "environment": [...], "allow": [...], "soft_deny": [...], "hard_deny": [...] }` | [see below] | Auto-mode classifier configuration |
| `permissionMode` | string | `"manual"`, `"auto"`, `"plan"`, `"acceptEdits"`, `"dontAsk"`, `"bypassPermissions"` | `"manual"` | Global permission mode (session can override) |
| `dangerouslySkipPermissionMode` | boolean | `true` \| `false` | `false` | Allow `--dangerously-skip-permissions` CLI flag |

**Permissions Structure (Complete):**
```json
{
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Bash(find :*)",
      "Bash(git *)",
      "WebFetch"
    ],
    "deny": [
      "Bash(sudo *)",
      "Bash(rm :*)"
    ],
    "ask": [
      "Edit(*.sensitive)"
    ],
    "defaultMode": "auto",
    "additionalDirectories": [
      "/path/to/allowed/directory"
    ],
    "disableAutoMode": "disable",
    "disableBypassPermissionsMode": "disable"
  }
}
```

**Permissions Keys:**
- `allow` — array of tool patterns to automatically allow
- `deny` — array of tool patterns to always deny (take precedence over allow)
- `ask` — array of tool patterns to always ask before executing
- `defaultMode` — which permission mode sessions start in (`"manual"`, `"auto"`, `"plan"`, `"acceptEdits"`, `"dontAsk"`, `"bypassPermissions"`)
- `additionalDirectories` — array of paths to grant file access beyond working directory
- `disableAutoMode` — set to `"disable"` to prevent auto mode from being used
- `disableBypassPermissionsMode` — set to `"disable"` to prevent bypassing permission checks

**Auto Mode Structure:**
```json
{
  "autoMode": {
    "environment": [
      "We're in a test environment with no production data",
      "Only safe bash commands should be auto-allowed"
    ],
    "allow": [
      { "reason": "Read-only", "rules": ["Read", "Bash(find :*)", "Bash(grep :*)"] }
    ],
    "soft_deny": [
      { "reason": "Network tools need review", "rules": ["WebSearch", "WebFetch"] }
    ],
    "hard_deny": [
      { "reason": "Destructive", "rules": ["Bash(rm :*)", "Bash(git reset --hard)"] }
    ]
  }
}
```

### D. Plugins & Marketplace

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `enabledPlugins` | object | `{ "plugin-id": true\|false, ... }` | {} | Which plugins are enabled |
| `pluginConfigs` | object | Plugin-specific config objects | {} | Per-plugin configuration |
| `extraKnownMarketplaces` | object | `{ "marketplace-id": { "source": {...} } }` | {} | Additional plugin marketplaces |
| `pluginBlocklist` | string[] | Plugin IDs | [] | Explicitly blocked plugins |
| `strictKnownMarketplaces` | string[] | Marketplace URLs/IDs | [] | Only allow these marketplaces (managed-only) |
| `blockedMarketplaces` | string[] | Marketplace URLs/IDs | [] | Block these marketplaces (managed-only) |

### E. MCP Servers & Tools

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `allowedMcpServers` | string[] | Server names | [] | MCP servers to enable |
| `disallowedMcpServers` | string[] | Server names | [] | MCP servers to disable |
| `enableAllProjectMcpServers` | boolean | `true` \| `false` | `false` | Auto-enable MCP servers from .claude/mcp.json |
| `disableClaudeAiConnectors` | boolean | `true` \| `false` | `false` | Disable claude.ai connectors |
| `strictMcpConfig` | boolean | `true` \| `false` | `false` | Only use MCP from `--mcp-config`, ignore others (CLI only) |

### F. Environment & Authentication

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `env` | object | `{ "VAR_NAME": "value", ... }` | {} | Environment variables passed to Claude and tools |
| `apiKeyHelper` | string | Path to executable | [use ANTHROPIC_API_KEY] | Shell command to fetch API key/token dynamically (called once per request; receives no stdin; outputs plain token) |
| `awsCredentialExport` | string | `"instance"`, `"profile"`, `"sso"` | [detect automatically] | How to export AWS credentials to sandboxed commands |
| `claudeCloudUrl` | string | URL | `"https://claude.ai"` | Alternative Claude Cloud URL |
| `oauthClientId` | string | OAuth client ID | [Anthropic's] | Override OAuth client ID |

### G. Hooks & Automation

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `hooks` | object | `{ "EventName": [ { ... } ] }` | {} | Lifecycle hooks for automation (31 event types supported) |
| `statusLine` | string | Path to executable | [none] | Custom status bar script (receives JSON on stdin, outputs formatted text) |

**Hook Events (31 Complete Types):**

Session Lifecycle:
- `SessionStart` — When a session begins or resumes
- `SessionEnd` — When a session terminates
- `Setup` — When `--init-only`, `--init`, or `--maintenance` flag used

User Input & Expansion:
- `UserPromptSubmit` — When user submits a prompt before Claude processes it
- `UserPromptExpansion` — When user-typed command expands into prompt

Tool Execution:
- `PreToolUse` — Before a tool call executes
- `PostToolUse` — After a tool call succeeds
- `PostToolUseFailure` — After a tool call fails
- `PostToolBatch` — After full batch of parallel tool calls resolves

Permissions & Security:
- `PermissionRequest` — When a tool call needs a permission decision
- `PermissionDenied` — When tool call denied by auto mode classifier

Subagents & Collaboration:
- `SubagentStart` — When a subagent is spawned
- `SubagentStop` — When a subagent finishes
- `TeammateIdle` — When agent team teammate about to go idle

Configuration & Files:
- `ConfigChange` — When a configuration file changes during session
- `CwdChanged` — When working directory changes (e.g., `cd` command)
- `DirectoryAdded` — When working directory added via `/add-dir`
- `FileChanged` — When a watched file changes on disk
- `InstructionsLoaded` — When CLAUDE.md or `.claude/rules/*.md` file loaded

Context & Compaction:
- `PreCompact` — Before context compaction
- `PostCompact` — After context compaction completes

Response & Messages:
- `Stop` — When Claude finishes responding
- `StopFailure` — When turn ends due to API error
- `MessageDisplay` — While assistant message text is displayed

Worktree Management:
- `WorktreeCreate` — When worktree being created via `--worktree`
- `WorktreeRemove` — When worktree being removed

Tasks:
- `TaskCreated` — When a task is being created via TaskCreate
- `TaskCompleted` — When a task is being marked as completed

User Interaction (MCP):
- `Elicitation` — When MCP server requests user input
- `ElicitationResult` — After user responds to MCP elicitation

UI:
- `Notification` — When Claude Code sends a notification

**Hook Entry Object Structure:**
```json
{
  "EventName": [
    {
      "matcher": "ToolName|regex",
      "hooks": [
        {
          "type": "command|http|mcp_tool|prompt|agent",
          "command": "/path/to/script.sh",
          "url": "http://...",
          "server": "server_name",
          "tool": "tool_name",
          "prompt": "...",
          "model": "fast-model",
          "if": "Bash(git *)",
          "timeout": 600,
          "statusMessage": "...",
          "args": [],
          "async": false,
          "once": false
        }
      ]
    }
  ]
}
```

**Matcher Semantics:**
- Exact match: `"Bash"`, `"Edit"`, `"Write"` (case-sensitive, alphanumerics, underscores, hyphens)
- Regex patterns: any other characters treated as JavaScript regex (unanchored)
- Multiple values: pipe-separated (`"Edit|Write"`) or comma-separated (`"Edit, Write"`)
- For MCP tools: naming convention `"mcp__<server>__<tool>"`
- Empty matcher `""` matches all occurrences

### H. Terminal, UI & Display

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `outputStyle` | string | Style name (e.g., `"default"`, `"minimal"`, `"focus"`) | `"default"` | Output formatting style (requires restart) |
| `theme` | string | `"light"`, `"dark"`, `"auto"` | `"auto"` | Color theme |
| `verbose` | boolean | `true` \| `false` | `false` | Show detailed diagnostic output |
| `axScreenReader` | boolean | `true` \| `false` | `false` | Render for screen readers (flat text, no decorations) |
| `editorMode` | string | `"vim"`, `"emacs"`, `"vscode"` | `"vscode"` | Line editor key bindings |
| `emojiCompletionEnabled` | boolean | `true` \| `false` | `true` | Enable emoji shortcode autocomplete (`:heart:` → ❤️) |
| `statusLine` | object | Command script (see Hooks section) | [none] | Custom status bar with context info |

### I. Agent & Subagent Control

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `agent` | string | Agent name/ID | [default] | Default agent for sessions |
| `agents` | object | `{ "name": { "description": "...", "prompt": "...", ... } }` | {} | Custom agent definitions |
| `subagentModel` | string | Model ID | [inherits from parent] | Model for subagents |
| `subagentToolRestrictions` | object | Tool restrictions for subagents | [inherit] | Which tools subagents can use |
| `subagentPermissionMode` | string | Permission mode for subagents | [inherit] | Permission mode for subagents |
| `maxConcurrentSubagents` | number | Integer | 20 | Max parallel subagents in one message |
| `maxSubagentSpawnDepth` | number | Integer | 3 | Max nesting depth (v2.1.219+) |

### J. Workflow & Automation

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `workflowSizeGuideline` | string | `"small"`, `"medium"`, `"large"`, `"unlimited"` | `"medium"` | Suggested workflow agent complexity |

### K. Browser & Artifact Display

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `disableBrowserExternalNavigation` | boolean | `true` \| `false` | `false` | Block external navigation in embedded browser (managed-only) |
| `disableMobileSimulatorTools` | boolean | `true` \| `false` | `false` | Disable mobile device emulation (managed-only) |

### L. Updates & Maintenance

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `autoUpdatesChannel` | string | `"latest"`, `"stable"` | `"latest"` | Which update channel to follow (latest = most recent; stable = one week old, skips major regressions) |
| `autoUpdatesDisabled` | boolean | `true` \| `false` | `false` | Disable automatic updates entirely (or set `DISABLE_AUTOUPDATER` env var) |
| `skipDangerousModePermissionPrompt` | boolean | `true` \| `false` | `false` | Don't ask about bypassing permissions (auto-agrees) |

### M. Telemetry & Privacy

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `DISABLE_TELEMETRY` (env var) | boolean | `"1"` = disable | [telemetry enabled] | Disable all telemetry (set in env block) |
| `DO_NOT_TRACK` (env var) | boolean | `"1"` = disable | [telemetry enabled] | Standard DNT header (set in env block) |
| `DISABLE_ERROR_REPORTING` (env var) | boolean | `"1"` = disable | [error reporting enabled] | Disable crash/error reporting (set in env block) |

### N. Sandbox & Network Security

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `sandbox.network.strictAllowlist` | boolean | `true` \| `false` | `false` | Deny non-allowlisted hosts without prompting |
| `sandbox.filesystem.disabled` | boolean | `true` \| `false` | `false` | Skip filesystem isolation (keep network egress control) |
| `sandbox.filesystem.denyWrite` | string[] | Paths to protect from writes | [] | Paths sandboxed commands cannot modify |
| `sandbox.credentials` | object | Credential masking config | {} | How to mask credentials in sandboxed commands |

### O. Attribution & Metadata

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `attribution` | object | `{ "commit": "...", "pr": "..." }` | {} | Attribution metadata for git commits |
| `includeCoAuthoredBy` | boolean | `true` \| `false` | `false` | Add Co-Authored-By trailers to commits |

### P. Managed-Only Settings

These settings ONLY work when delivered through managed sources and cannot be set in user/project files:

| Key | Type | Legal Values | Purpose |
|-----|------|--------------|---------|
| `allowManagedHooksOnly` | boolean | `true` \| `false` | Reject user-defined hooks |
| `allowManagedMcpServersOnly` | boolean | `true` \| `false` | Reject user-added MCP servers |
| `allowManagedPermissionRulesOnly` | boolean | `true` \| `false` | Reject user-defined permissions |
| `allowManagedPluginsOnly` | boolean | `true` \| `false` | Reject user-installed plugins |
| `allowManagedAgentsOnly` | boolean | `true` \| `false` | Reject custom agents |
| `allowManagedOutputStylesOnly` | boolean | `true` \| `false` | Reject custom output styles |
| `allowManagedThemesOnly` | boolean | `true` \| `false` | Reject custom themes |
| `allowManagedKeybindingsOnly` | boolean | `true` \| `false` | Reject custom keybindings |
| `channelsEnabled` | string[] | Channel IDs | Which AI channels are available |
| `disableSideloadFlags` | boolean | `true` \| `false` | Disable `--plugin-dir` and `--plugin-url` |
| `claudeMd` | object | CLAUDE.md override | Override discovered CLAUDE.md |
| `deniedMcpServers` | string[] | Server names | Explicitly deny MCP servers |
| `strictKnownMarketplaces` | string[] | Marketplace URLs | Allowlist only these marketplaces |
| `blockedMarketplaces` | string[] | Marketplace URLs | Block these marketplaces |
| `forceRemoteSettingsRefresh` | boolean | `true` \| `false` | Fail startup if managed settings unavailable |

### Q. Remote Control & Collaboration (newer features)

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `remoteControlAtStartup` | boolean | `true` \| `false` | `false` | Enable Remote Control on session start |
| `remoteControlSessionNamePrefix` | string | Text | [hostname] | Prefix for auto-generated Remote Control session names |

### R. Beta & Experimental Features

| Key | Type | Legal Values | Default | Description |
|-----|------|--------------|---------|-------------|
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (env var) | boolean | `"1"` = enable | [disabled] | Enable experimental agent teams feature |
| `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR` (env var) | boolean | `"1"` = enable | [disabled] | Bash maintains project working directory (v2.1.223+) |

---

## Part 4: Command-Valued Settings Contracts

Two settings allow executing external commands to provide dynamic values or formatting.

### statusLine (Custom Status Bar)

**Purpose:** Display dynamic context in the status bar (token usage, branch, cost, etc.)

**Setting:**
```json
{
  "statusLine": "~/.local/bin/claude-status-bar"
}
```

**Contract:**

| Aspect | Details |
|--------|---------|
| **Input (stdin)** | Deeply nested JSON object (see schema below)<br>**Field presence:** Most fields may be absent (not null, but completely missing) depending on context<br>Examples: `session_name` absent until custom name exists; `worktree` absent outside worktree session; `pr` absent until PR linked |
| **Output (stdout)** | ANSI-formatted text for display<br>Can be single-line or multi-line<br>Supports ANSI colors and styles |
| **Stderr** | Ignored |
| **Exit code** | 0 = success; any non-zero suppresses output |
| **Timeout** | Default: 1 second |
| **Reload** | Takes effect immediately; called every prompt refresh |
| **Example output** | `[Opus] main | 8.5K/200K tokens (4%) | $0.01 | 2m 30s` |

**Complete stdin JSON Schema:**
```json
{
  "cwd": "/current/working/directory",
  "session_id": "abc123...",
  "session_name": "my-session",
  "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
  "transcript_path": "/path/to/transcript.jsonl",
  "model": {
    "id": "claude-opus-5",
    "display_name": "Opus"
  },
  "workspace": {
    "current_dir": "/current/working/directory",
    "project_dir": "/original/project/directory",
    "added_dirs": [],
    "git_worktree": "feature-xyz",
    "repo": {
      "host": "github.com",
      "owner": "anthropic",
      "name": "claude-code"
    }
  },
  "version": "2.1.224",
  "output_style": {
    "name": "default"
  },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_api_duration_ms": 2300,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "context_window": {
    "total_input_tokens": 15500,
    "total_output_tokens": 1200,
    "context_window_size": 200000,
    "used_percentage": 8,
    "remaining_percentage": 92,
    "current_usage": {
      "input_tokens": 8500,
      "output_tokens": 1200,
      "cache_creation_input_tokens": 5000,
      "cache_read_input_tokens": 2000
    }
  },
  "exceeds_200k_tokens": false,
  "fast_mode": false,
  "effort": {
    "level": "high"
  },
  "thinking": {
    "enabled": true
  },
  "rate_limits": {
    "five_hour": {
      "used_percentage": 23.5,
      "resets_at": 1738425600
    },
    "seven_day": {
      "used_percentage": 41.2,
      "resets_at": 1738857600
    }
  },
  "vim": {
    "mode": "NORMAL"
  },
  "agent": {
    "name": "security-reviewer"
  },
  "pr": {
    "number": 1234,
    "url": "https://github.com/anthropic/claude-code/pull/1234",
    "review_state": "pending"
  },
  "worktree": {
    "name": "my-feature",
    "path": "/path/to/.claude/worktrees/my-feature",
    "branch": "worktree-my-feature",
    "original_cwd": "/path/to/project",
    "original_branch": "main"
  }
}
```

**Field Presence Notes:**
- **May be absent (not in JSON):** `session_name`, `prompt_id`, `workspace.git_worktree`, `workspace.repo`, `effort`, `vim`, `agent`, `pr`, `worktree`
- **May be null:** `context_window.current_usage`, `context_window.used_percentage`, `context_window.remaining_percentage` (early in session or after `/compact`)

**Example Script:**
```bash
#!/bin/bash
read -r json
model=$(echo "$json" | jq -r '.model.display_name // "Claude"')
branch=$(echo "$json" | jq -r '.workspace.repo.branch // "unknown"')
used=$(echo "$json" | jq -r '.context_window.total_input_tokens // 0')
limit=$(echo "$json" | jq -r '.context_window.context_window_size // 0')
cost=$(echo "$json" | jq -r '.cost.total_cost_usd // 0' | xargs printf '%.2f')
echo "[$model] $branch | ${used}/$limit tokens | \$$cost"
```

### apiKeyHelper (Dynamic API Key Provider)

**Purpose:** Fetch API keys/tokens dynamically (for rotating keys, AWS federation, credential managers, etc.)

**Setting:**
```json
{
  "apiKeyHelper": "aws-vault exec my-profile -- sh -c 'echo $ANTHROPIC_API_KEY'"
}
```

**Contract:**

| Aspect | Details |
|--------|---------|
| **Input (stdin)** | Empty (no input provided) |
| **Output (stdout)** | Plain API key or token (single line, no trailing whitespace, no quotes) |
| **Stderr** | Ignored |
| **Exit code** | 0 = success; non-zero = failure (falls back to env var or keychain) |
| **Timeout** | Default: 5 seconds |
| **Reload** | Takes effect immediately; called for each API request |
| **Used as** | Both `X-Api-Key: <token>` header AND `Authorization: Bearer <token>` (API-context dependent) |
| **Error handling** | If script fails, falls back to `ANTHROPIC_API_KEY` env var, then system keychain |
| **TTL/Caching** | Configurable via `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` env var |

**Example Scripts:**

Credential manager:
```bash
#!/bin/bash
pass show anthropic/api-key
```

AWS credential federation:
```bash
#!/bin/bash
aws-vault exec my-profile -- sh -c 'echo $ANTHROPIC_API_KEY'
```

Token rotation:
```bash
#!/bin/bash
curl -s https://keyserver.internal/issue-token | jq -r '.token'
```

---

## Part 5: Special Behaviors and Quirks

### Settings That Require Restart
Most settings take effect immediately, but these require restarting the Claude Code session:
- `outputStyle` (output formatting style)
- Some OpenTelemetry configuration keys (`OTEL_EXPORTER_OTLP_ENDPOINT`, etc.)

### Permissions Merging Behavior
When multiple scopes define permissions, rules are MERGED (combined), not replaced:

```json
// ~/.claude/settings.json
{ "permissions": { "allow": ["Read", "Edit"] } }

// .claude/settings.json
{ "permissions": { "deny": ["Bash(rm :*)"] } }

// Result: allow Read, Edit; deny Bash(rm :*)
```

### Environment Variable Handling
1. Variables in `env` block are passed to Claude and tool executions
2. Admin-managed auth/proxy vars are withheld until server confirms (v2.1.198+)
3. Per-key merging (v2.1.223+): Admin and user env vars merge per key, no block-level override

### Invalid Settings Behavior (v2.1.169+)
- Invalid entries are stripped from settings with a warning
- Valid entries still apply
- Sessions continue with degraded config (tolerant parsing)

### Workspace Trust
- Settings files outside a trusted directory require trust dialog
- `.claude/settings.local.json` is NOT read by auto-mode classifier (security)
- CLAUDE.md discovery is workspace-trust-aware

---

## Part 6: Workspace Trust Configuration

**CRITICAL:** Workspace trust settings are stored in `~/.claude.json`, NOT in `settings.json` files. They control whether `.claude/settings.json` permission rules take effect.

### Trust-Related Storage

**Location:** `~/.claude.json` (runtime state file)

**Keys:**
- `projects[<exact_path>].hasTrustDialogAccepted` — boolean; set to `true` to persist workspace trust
- `hasTrustDialogHooksAccepted` — boolean; controls trust for hooks specifically

**Structure in `~/.claude.json`:**
```json
{
  "projects": {
    "/absolute/path/to/workspace": {
      "hasTrustDialogAccepted": true,
      "hasTrustDialogHooksAccepted": true
    }
  }
}
```

### Trust Prompt Behavior

**Dialog appears when:**
- First-time launch in a project
- `.claude/settings.json` contains `allow` rules or `additionalDirectories`
- User hasn't previously accepted trust for that workspace path

**Dialog suppressed when:**
- Running with `-p` flag (non-interactive/print mode)
- Launching from home directory (`~`) — trust held for session only, not persisted
- Parent directory already trusted (v2.1.200+)

**Trust dialog appears BEFORE settings are read** (security feature CVE-2026-33068):
- Prevents malicious repos from bypassing trust via `permissions.defaultMode = bypassPermissions`
- Ensures user sees what they're trusting before permission rules apply

### Permission System Integration

**Permissions requiring trust:**
- `allow` rules — restrictive; require workspace trust
- `additionalDirectories` — grant file access outside working directory; require trust
- `ask` rules — always apply (don't require trust; user gets prompt)
- `deny` rules — always apply (safe; restrictive)

**After trust accepted:**
- All permission rules in `.claude/settings.json` become active
- Future sessions in that directory use accepted trust

### Home Directory Edge Case

**Issue:** Starting Claude Code in home directory (`~`) shows trust dialog but doesn't persist it.

**Behavior:**
- Trust is held for the current session only
- On next launch from home directory, dialog appears again
- No settings.json configuration can override this (design choice)

**Workaround:** Start Claude Code from a project subdirectory instead of home directory.

### Manual Trust Bypass

If needed (e.g., trust dialog broken), manually edit `~/.claude.json`:
```json
{
  "projects": {
    "/absolute/path/to/workspace": {
      "hasTrustDialogAccepted": true,
      "hasTrustDialogHooksAccepted": true
    }
  }
}
```

---

## Part 7: Linux-Specific Paths and Details

### Installation Locations
```
/home/wil/.local/bin/claude           # User-specific install (this system)
/opt/claude/bin/claude                 # System-wide install (alternative)
/usr/local/bin/claude                  # System-wide install (alternative)
```

### Version Installation
```
~/.local/share/claude/versions/2.1.224/   # Installed version binaries
~/.local/share/claude/                    # Claude Code installation root
```

### Managed Settings Paths
```
/etc/claude-code/managed-settings.json      # System-wide policy
/etc/claude-code/managed-settings.d/*.json  # Modular policy files
```

### Configuration Caching
```
~/.claude/remote-settings.json   # Cached server-managed settings
~/.claude/.last-update-result.json  # Last auto-update result
~/.claude/.last-cleanup          # Timestamp of last cleanup
```

### Process Environment
- Claude Code inherits user shell environment
- `CLAUDE_*` prefixed vars override settings at startup
- `DISABLE_TELEMETRY=1` disables feature-flag evaluation and Remote Control

---

## Part 8: File Permissions and Security

| File | Permissions | Purpose | Sensitive? |
|------|-------------|---------|-----------|
| `~/.claude/settings.json` | 644 (rw-r--r--) | User settings | No |
| `~/.claude/.credentials.json` | 600 (rw-------) | Credentials | YES |
| `~/.claude/history.jsonl` | 600 (rw-------) | Conversation history | YES |
| `~/.claude.json` | 600 (rw-------) | Session state | YES |
| `~/.local/bin/claude` | 755 (rwxr-xr-x) | CLI executable | No |
| `.claude/settings.json` | 644 (rw-r--r--) | Project settings | No |
| `.claude/settings.local.json` | Varies | Local overrides | Optionally sensitive |

**Security Notes:**
- Credentials file is user-only (600)
- History contains full conversations (user-only)
- Session state includes sensitive info (user-only)
- Project settings can be committed to version control (no secrets)
- Local overrides should be .gitignored if they contain secrets

---

## Part 9: Feature Versions and Changes

### Recent Additions (v2.1.223–v2.1.224)
- `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR` env var (maintain cwd for Bash)
- Managed settings env per-key merging (v2.1.223+)
- Auto-mode classifier improvements for security
- Subagent nesting up to depth 3 (v2.1.219+, default was 1 in v2.1.217–v2.1.218)
- Background subagent improvements (v2.1.221+)

### Recent Removals
- Ultraplan feature (removed in v2.1.222)
- Opus 4.7 from fast mode (v2.1.219+)

### Security Fixes
- Bash permission bypass fixes (v2.1.223, v2.1.221)
- Admin env withholding for proxy/TLS/auth vars (v2.1.198+)
- Local settings not read by auto-mode classifier (security feature)
- Permission rules bypassing fixed in multiple versions

### Behavior Changes
- `/code-review` is now an alias of `/review` (v2.1.223)
- Remote Control at startup restricted to user settings only (v2.1.221+)
- Background sessions commit and push by default (v2.1.221+)
- Plugins activate immediately on install when safe (v2.1.221+)

---

## Part 10: Undocumented/Observable Settings

The following settings appear in observed configurations or CLI help but lack clear official documentation:

| Key | Type | Observed Behavior | Uncertainty |
|-----|------|-------------------|-------------|
| `DISABLE_TELEMETRY` | env var | Disables feature-flag evaluation, Remote Control | Partial documentation |
| `CLAUDE_CODE_SIMPLE` | env var (via `--bare`) | Skips hooks, LSP, plugin sync | Documented in `--bare` flag only |
| `CLAUDE_CODE_SAFE_MODE` | env var (via `--safe-mode`) | Disables customizations but keeps auth/model | Documented in `--safe-mode` flag only |
| `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST` | env var | Host-managed model selection precedence | Very limited documentation |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT` | env var | Limits 1M models to 200K (auto-compact) | Changelog only |
| `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` | env var | Limits parallel subagents (default 20) | Changelog only |
| `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` | env var | Limits subagent nesting depth | Changelog only |

**Note:** These are explicitly documented in the changelog and help text, but not in the main settings documentation.

---

## Conclusion

The Claude Code configuration system is extensive, well-designed, and security-conscious. Key design principles:

1. **Declarative Settings:** All configuration is JSON-based, without scripting
2. **Layered Precedence:** Clear hierarchy from defaults through managed policy to in-session overrides
3. **Secure Defaults:** Auto-mode classifier avoids dangerous local file injection; credentials are user-only
4. **Flexible Automation:** Hooks and command-valued settings enable integration with external tools
5. **Enterprise Ready:** Managed settings support corporate policy enforcement without user override

For the config-weave package, this provides a comprehensive target surface for declarative management of Claude Code on Linux systems.

