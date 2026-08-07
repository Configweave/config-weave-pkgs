# Research: MCP Server Configuration for Claude Code on Linux

**Date:** 2026-08-07  
**Goal:** Understand MCP server configuration scopes, transports, approval mechanisms, and convergence detection to inform design of a declarative `claude_code` package for config-weave.

---

## 1. Configuration Locations and Scopes

### File Paths on Linux

| Scope | File Path | Applies To | Requires Approval |
|-------|-----------|-----------|----------|
| **Local** | `~/.claude.json` (project-specific key) | Current project only | No — user controls |
| **Project** | `.mcp.json` (repo root) | All users in this repo | **Yes** — per-server, per-user |
| **User** | `~/.claude.json` (top-level key) | All projects | No — user-scoped auto-load |

**Precedence (highest to lowest):**
1. **Local scope** — project-specific entry in `~/.claude.json.projects[path].mcpServers`
2. **Project scope** — servers in `.mcp.json`
3. **User scope** — top-level `mcpServers` in `~/.claude.json`

**Critical path behavior:** Narrower/closer scope overrides broader scope. If a server appears in both `.mcp.json` and user scope, the project copy takes precedence.

**Environment override:** `CLAUDE_CONFIG_DIR` can override the default `~/.claude.json` location.

**Enterprise managed settings:** Separate configuration system (see section 7); not a scope per se.

---

## 2. JSON Schema for MCP Server Entry

### HTTP/SSE Format
```json
{
  "mcpServers": {
    "server-name": {
      "type": "http",           // or "sse"
      "url": "https://mcp.example.com/mcp",
      "env": {
        "API_KEY": "${API_KEY}",
        "CUSTOM_VAR": "value",
        "OPTIONAL_WITH_DEFAULT": "${VAR:-fallback}"
      }
    }
  }
}
```

**Required fields:**
- `type`: One of `http`, `sse`, or `stdio`
- `url` (HTTP/SSE): HTTPS endpoint
- `command` + `args` (stdio): Executable + arguments array

**Optional fields:**
- `env`: Environment variables (supports `${VAR}` and `${VAR:-default}` expansion)

### Stdio (Local Subprocess) Format
```json
{
  "mcpServers": {
    "local-tool": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest"],
      "env": {
        "BROWSER": "firefox"
      }
    }
  }
}
```

### Field Validation
- `type`: Validated at server addition time; invalid types rejected with parse error
- `url`: HTTP GET test performed at addition time (server must be reachable)
- `command`: Validated for executable existence at session start
- `env`: Variables expanded at connection time; missing vars default to empty string unless `${VAR:-default}` form used

---

## 3. Scope Precedence Rules

**When Claude Code loads MCP servers, precedence is (highest first):**

1. **Local scope** (`~/.claude.json` for this project)
   - User's choice for this project only
   - Takes precedence over project/user scopes
   
2. **Project scope** (`.mcp.json` in repo root)
   - Team/repo definition
   - Visible to all users who clone
   - Requires per-user, per-server approval on first use
   
3. **User scope** (top-level `mcpServers` in `~/.claude.json`)
   - User-wide default
   - No approval needed (user already installed it)

**Conflict resolution:** If the same server name appears in multiple scopes, the highest-precedence scope's definition is used. The server connects only once.

**Note on managed settings:** Enterprise MCP mandating (if supported) goes through managed settings configuration, not through scope precedence. (Unconfirmed—see section 7.)

---

## 4. Transport Types and Their Fields

### HTTP
- **Type value:** `"http"`
- **Required:** `url` (HTTPS endpoint)
- **Optional:** `env` (API keys, custom headers)
- **Auth:** Static bearer token via CLI (`--header "Authorization: Bearer ..."`), or OAuth 2.0 via `login` command
- **Typical use:** Hosted MCP services (GitHub, Sentry, Anthropic's claude.ai connectors)
- **Validation:** Deferred to session start or `claude mcp list` (no connectivity test at add time)

### SSE (Server-Sent Events)
- **Type value:** `"sse"`
- **Required:** `url` (HTTPS endpoint with SSE stream)
- **Optional:** `env`, custom headers
- **Auth:** Bearer token or OAuth
- **Typical use:** Streaming, webhooks, long-lived connections
- **Validation:** Deferred to session start or `claude mcp list`
- **Note:** CLI help text mentions "WebSocket headers" for this transport (misleading — WebSocket is not a supported transport type)

### Stdio (Local Subprocess)
- **Type value:** `"stdio"`
- **Required:** `command` (executable name or path), `args` (array of arguments)
- **Optional:** `env` (environment variables for subprocess)
- **Auth:** N/A (local; can use env vars for secrets)
- **Typical use:** Local tools (playwright, file system access), browser control, debugging
- **Validation:** Command existence checked at session start (not at add time)

### Environment Variable Expansion
All transport types support `env` field:
```json
"env": {
  "API_KEY": "${API_KEY}",           // reads $API_KEY from host env
  "FALLBACK": "${MISSING:-default}", // uses 'default' if $MISSING not set
  "LITERAL": "no_expansion"          // literal value
}
```

**Important:** Expansion happens at connection time. Host machine's environment must have the variable, or it defaults to empty string (or specified default).

---

## 5. Approval Mechanism: How Project-Scoped Servers Load Unattended

### The Interactive Flow
**Project-scoped servers (`.mcp.json`) require user approval before loading.** This is intentional—prevents cloned repositories from auto-executing untrusted code without explicit consent.

**Default interactive flow:**
1. User clones repo with `.mcp.json` containing undefined servers
2. Claude Code detects servers in `.mcp.json` on next session
3. Shows "⏸ Pending approval" in `/mcp` panel
4. User clicks "Approve" or "Reject" for each server
5. Choice is recorded in `~/.claude.json`
6. Server auto-connects on future sessions

### Approval Recording Location

**File:** `~/.claude.json`

**Exact key path:**
```
.projects["/absolute/path/to/project"].enabledMcpjsonServers[]
.projects["/absolute/path/to/project"].disabledMcpjsonServers[]
```

**Structure (example):**
```json
{
  "projects": {
    "/home/wil/orca/config-weave-pkgs": {
      "enabledMcpjsonServers": ["playwright", "github-api"],
      "disabledMcpjsonServers": ["untrusted-server"]
    }
  }
}
```

**What's recorded:**
- Server name (user-assigned label in `.mcp.json`)
- Project's **absolute filesystem path**
- Array membership: enabled vs. disabled
- NOT the URL or command (for privacy)

### The Unattended Path: Pre-Writing Approval State

**Yes, unattended loading is possible for project-scoped servers.** A configuration management tool can:

1. Write the `.mcp.json` file with server definitions
2. **Write the approval state directly** to `~/.claude.json.projects["{project-path}"].enabledMcpjsonServers[]`

This bypasses the interactive approval prompt entirely. The server loads silently on next session without `/mcp` UI approval.

**Example resource workflow:**
```wcl
# Step 1: Write project-scope server definition
resource "claude_code_project_mcp" "github" {
  project_path = "/home/wil/orca/config-weave-pkgs"
  server_name = "github-api"
  type = "http"
  url = "https://api.github.com/v1/mcp"
}

# Step 2: Pre-approve the server (unattended)
resource "json_key" "approve_github_api" {
  file = "~/.claude.json"
  key_path = ".projects[\"/home/wil/orca/config-weave-pkgs\"].enabledMcpjsonServers"
  value_append = "github-api"  # Append to array if key-path resource supports it
}
```

**Critical caveats:**

1. **Project path must be exact:** The path in `~/.claude.json.projects["{path}"]` key must match exactly where Claude Code resolves the project. See section 5a for path matching details.

2. **Path normalization uncertain:** Documentation does not specify whether paths are:
   - Exact filesystem strings (no normalization)
   - Canonicalized (symlinks resolved)
   - Relative-to-absolute expanded
   
   **Recommendation:** Always use the absolute path that Claude Code would report in `claude mcp list --json` (if available) or from `.projects` keys in an existing `~/.claude.json` for the same project.

3. **Worktree handling:** Claude Code has special logic for git worktrees; if the project is in a worktree, the path key may be different than the checkout location. Document to resolve through `git rev-parse --show-toplevel` on the actual machine.

### Alternative Unattended Strategies

#### Option A: User-Scoped Servers (No Approval)
```bash
# Add to user scope (applies everywhere, no approval needed)
claude mcp add --scope user --transport http myserver https://mcp.example.com/api
```
- Loads automatically in all projects
- User chooses it globally; no per-project prompt
- Useful for personal tools (GitHub, Sentry, etc.)
- **Trade-off:** Loses per-project control; server available everywhere

#### Option B: Managed Settings (Enterprise, No Approval, Unconfirmed)
Anthropic documentation suggests enterprise MCP mandating through managed settings (exact mechanism unconfirmed on Linux).
- System admin deploys via MDM, GPO, or fleet management
- Loads automatically for all users (if supported)
- No per-user approval (if supported)
- **Trade-off:** Requires administrator access; not verified locally
- **Recommendation:** For config-weave, document that managed MCP is system-admin-only and architecture is uncertain

#### Option C: Local-Scoped Servers (No Approval, Project-Local)
```json
// ~/.claude.json, projects["/this/project/path"].mcpServers
{
  "projects": {
    "/home/wil/orca/config-weave-pkgs": {
      "mcpServers": {
        "local-server": {
          "type": "http",
          "url": "https://local.example.com/mcp"
        }
      }
    }
  }
}
```
- Loads silently (local scope, no approval)
- Project-specific (other projects don't see it)
- Requires writing to user's `~/.claude.json` (user-writable, not version-controlled)
- **Trade-off:** Cannot be committed to `.mcp.json`; each user must have it

**Conclusion:** Project-scoped servers **can** converge unattended if a configuration tool writes both `.mcp.json` (definition) and the approval state in `~/.claude.json` (enablement). Path matching is the critical variable to verify.

### Approval State Values

**Server can be in one of these states:**

| State | Key | Loads? | Recording |
|-------|-----|--------|-----------|
| Approved | `enabledMcpjsonServers[server-name]` | Yes | Entry in array |
| Rejected | `disabledMcpjsonServers[server-name]` | No | Entry in array |
| Pending | (no entry in either array) | No, shows ⏸ | Nothing recorded |

---

## 5a. Path Matching: Caveat for Configuration Management

**Problem:** Approval state is keyed by `~/.claude.json.projects["/absolute/path/to/project"]`. For convergence to work, the path key must match exactly where Claude Code resolves the project.

**Unknowns (not documented by Anthropic):**
1. Are paths exact filesystem strings, or canonicalized (symlinks resolved)?
2. What happens if a repo is cloned to a different location than originally approved?
3. How does Claude Code handle git worktrees—does it store the worktree path or the main repo path?
4. Does path normalization occur (e.g., redundant slashes removed)?

**Safe approach for config-weave resources:**
- Always use the absolute filesystem path where the resource runs: `$(pwd)` or `$(cd . && pwd)`
- Document that MCP approval is keyed to that checkout location
- If the project is moved or checked out elsewhere, old approvals won't transfer (user must re-approve or tool must migrate the keys)
- Test on actual machines to verify path key after writing

---

## 6. File and Key Path: Approval Recording Detail (Detailed Reference)

### Complete Path to Approval Data

```
~/.claude.json
  .projects["{project-absolute-path}"]
    .enabledMcpjsonServers[]      # Array of approved server names
    .disabledMcpjsonServers[]     # Array of rejected server names
```

### Example with Real Path

Project: `/home/wil/orca/config-weave-pkgs`

**After user approves "playwright" and "github-api" servers:**
```json
{
  "projects": {
    "/home/wil/orca/config-weave-pkgs": {
      "enabledMcpjsonServers": ["playwright", "github-api"],
      "disabledMcpjsonServers": []
    }
  }
}
```

### CLI to Inspect Approval State
```bash
# See approvals for this project
jq '.projects["/home/wil/orca/config-weave-pkgs"] | {enabledMcpjsonServers, disabledMcpjsonServers}' ~/.claude.json

# Clear all approvals (resets to pending)
claude mcp reset-project-choices
```

### What Triggers Recording

- **Approval:** User clicks "Approve" in `/mcp` UI during session
- **Rejection:** User clicks "Reject" (or equivalent)
- **Persistence:** Choice is written to `~/.claude.json` immediately; future sessions honor it

**Note:** Dismissing the prompt does NOT record approval; server stays pending.

---

## 7. Enterprise-Level MCP Settings and Managed Servers

### Managed MCP Configuration: Unconfirmed Separate File

**Observed:** `/etc/claude-code/` directory does not exist on this machine.

**Documentation claim (not verified on this machine):** Anthropic documentation may refer to managed MCP configuration, but the file location and whether it's separate from `managed-settings.json` could not be confirmed on Linux.

**Uncertainty:** Cannot confirm whether this is a separate file from `managed-settings.json` or whether MCP mandating goes entirely through managed settings instead. The distinction matters for configuration management.

**If present:** Would provide exclusive control—users cannot add, modify, or disable other servers.

**Recommended approach for config-weave:** Document that managed MCP configuration is system-administrator-only (if supported). Avoid assuming the file path without verified documentation or observed evidence.

### Three Enterprise Patterns

#### Pattern 1: Fixed Server Set (Exclusive Control)
```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.github.com/v1/mcp"
    },
    "sentry": {
      "type": "http",
      "url": "https://mcp.sentry.dev/mcp"
    }
  }
}
```
**Result:** Users see only these servers; `claude mcp add` fails with "not allowed by enterprise policy" error.

#### Pattern 2: Disable MCP Entirely
```json
{
  "mcpServers": {}
}
```
**Result:** No MCP servers available; `/mcp` shows "MCP disabled by administrator."

#### Pattern 3: Allowlist and Denylist
Configured in `managed-settings.json` or via admin console:
```json
{
  "allowedMcpServers": [
    { "serverUrl": "https://api.github.com/*" },
    { "serverCommand": ["npx", "-y", "approved-package"] }
  ],
  "deniedMcpServers": [
    { "serverUrl": "https://*.untrusted-domain.com/*" }
  ],
  "allowManagedMcpServersOnly": false
}
```

### Allowlist/Denylist Matching Rules

**URL matching:**
- Exact: `https://mcp.example.com/api` (case-insensitive hostname)
- Wildcard: `https://mcp.example.com/*` (any path)
- Subdomain: `https://*.internal.example.com/*` (any subdomain)

**Command matching:**
- Exact array match: `["npx", "-y", "@playwright/mcp"]` must match exactly
- No partial matching; all args must be present

**Server name matching:**
- User-assigned label (least reliable for security)
- Use URL or command instead

**Denylist precedence:** Denied entries always override allowlist. Cannot approve a denied server.

### Settings Delivery Methods
- Server-managed settings (Anthropic's Claude Code admin console)
- `managed-settings.json` at system path
- MDM/GPO profiles
- Environment variables (limited — not for policies)

**No environment-based MCP policy override available** (unlike some other settings).

---

## 13. Convergence Checking: Reading Back Server Configuration

### Challenge
There is no single "read current MCP state" API. Convergence checking requires parsing multiple sources and using CLI inspection.

### Method 1: Direct File Parsing

```bash
# Project-scoped servers (raw definition)
cat .mcp.json | jq '.mcpServers'

# User-scoped servers
jq '.mcpServers // {}' ~/.claude.json | grep -v projects

# Project approval state (what's enabled/disabled)
PROJECT="/home/wil/orca/config-weave-pkgs"
jq ".projects[\"$PROJECT\"] | {enabledMcpjsonServers, disabledMcpjsonServers}" ~/.claude.json
```

### Method 2: CLI Inspection

```bash
# List all servers with connection status
claude mcp list

# Example output:
# ✔ Connected    github-api        http  https://api.github.com/v1/mcp
# ⏸ Pending      playwright        stdio npx -y @playwright/mcp
# ✘ Failed       sentry            http  (connection timeout)

# Get detailed config for one server
claude mcp get github-api

# Validate syntax (implicitly during session start)
# No dedicated validator; parse errors on session init
```

### Method 3: During Session

Within a Claude Code session (interactive):
```
/mcp              # Panel: status, connection state, scope, auth
/context          # Full context breakdown (shows which servers loaded)
/status           # Settings sources active (managed, user, project, local)
/doctor           # Setup audit (syntax errors, duplicates, missing auth)
/debug mcp        # Enable MCP connection debug logging
```

### Method 4: Programmatic Verification (Workaround)

For convergence validation in a config-weave package:

```bash
# Parse project .mcp.json
if [ -f .mcp.json ]; then
  jq '.mcpServers | keys' .mcp.json
fi

# Parse user scope
jq '.mcpServers // {} | keys' ~/.claude.json | grep -v projects

# Parse approval state
PROJECT_ABS_PATH="$(cd . && pwd)"
jq ".projects[\"$PROJECT_ABS_PATH\"].enabledMcpjsonServers // []" ~/.claude.json

# CLI check (requires parsing output)
claude mcp list | grep "✔ Connected"
```

### Limitations for Declarative Management

1. **No remote API** — cannot programmatically verify server connection
2. **CLI output parsing required** — `claude mcp list` returns human-readable text (not JSON)
3. **Approval is interactive** — no flag to skip project-scope approval
4. **No bulk reset** — `reset-project-choices` clears all; cannot selectively reset one server

**Recommendation:** For the `claude_code` config-weave package, focus on:
- Writing `.mcp.json` and user-scope servers (via key-path resource for `~/.claude.json`)
- Using `claude mcp list` CLI (with wrapper to parse) for verification
- Documenting that project-scoped server approval is a one-time interactive step post-convergence

---

## 14. What `claude mcp` CLI Commands Do (Beyond Editing Files)

### `claude mcp add`
```bash
claude mcp add [--scope local|project|user] [--transport http|stdio|sse] \
  [--header "Auth: Bearer X"] [--env VAR=val] <name> <url-or-command> [args...]
```

**Actions:**
1. Validates `name` is unique (if scope-wide)
2. **No connection test at add time** (deferred to session start)
3. **Executable check:** For stdio, verifies `command` exists (not full spawn)
4. Writes to `.mcp.json` (project scope) or `~/.claude.json` (user/local)
5. Prints filename written and success message

**Does NOT do:**
- Start the server
- Validate full stdio subprocess startup (only checks command exists)
- Run tool discovery (deferred to session start)

### `claude mcp remove`
```bash
claude mcp remove [--scope local|project|user] <name>
```

**Actions:**
1. Finds server in specified scope
2. Deletes entry from `.mcp.json` or `~/.claude.json`
3. Returns error if server not found or exists in multiple scopes without `--scope`

### `claude mcp list`
```bash
claude mcp list
```

**Output:** Human-readable table with:
- Server name
- Transport type (http, sse, stdio)
- Status: `✔ Connected`, `⏸ Pending approval`, `! Needs authentication`, `✘ Failed to connect`
- URL or command

**Does NOT:** Return JSON or machine-readable format (limitation for automation)

### `claude mcp get <name>`
```bash
claude mcp get <name>
```

**Output:** Server's JSON configuration, scope, and any connection errors.

**Does NOT:** Execute the server; only reads config.

### `claude mcp add-json [--scope local|project|user] <name> <json>`
```bash
claude mcp add-json --scope project myserver '{"type":"stdio","command":"npm","args":["run","mcp"]}'
```

**Actions:**
1. Parses JSON string
2. Validates schema (same as `add` command)
3. Writes to appropriate config file
4. Similar connection testing as `add`

**Use case:** Scripted/declarative MCP registration without interactive CLI.

### `claude mcp login <name>`
```bash
claude mcp login sentry-server
```

**Actions:**
1. Initiates OAuth 2.0 flow (interactive browser)
2. Stores credentials in `~/.claude.json` (encrypted/secure)
3. Server can now use authenticated APIs

**Limitation:** Requires user interaction (browser redirect).

### `claude mcp logout <name>`
```bash
claude mcp logout sentry-server
```

**Actions:**
1. Clears stored OAuth credentials
2. Server reverts to unauthenticated (or fails if auth required)

### `claude mcp reset-project-choices`
```bash
claude mcp reset-project-choices
```

**Actions:**
1. Clears `enabledMcpjsonServers` and `disabledMcpjsonServers` for all projects
2. All project-scoped servers revert to "⏸ Pending approval"
3. Next session will prompt user to re-approve

**Use case:** Testing approval flow, troubleshooting stale approvals.

### `claude mcp add-from-claude-desktop` (macOS/WSL only)
```bash
claude mcp add-from-claude-desktop
```

**Actions:**
1. Reads `~/Library/Application\ Support/Claude/claude_desktop_config.json` (macOS) or WSL path
2. Imports servers, converts to Claude Code format
3. Adds to user scope (not project)

**Limitation:** macOS/WSL only; Linux has no Desktop app.

### What CLI Does NOT Do

- **Does NOT start/stop servers** — registration only
- **Does NOT validate startup** — deferred to session init
- **Does NOT expose tool definitions** — tool listing only via session `/mcp` panel
- **Does NOT bulk-configure** — one server at a time
- **Does NOT offer templates** — no quick-start configs

---

## 10. Detection: How to Verify a Server's Presence and Definition

### For Configuration Convergence

**Goal:** Ensure a machine has converged to the desired MCP configuration (used to validate the config-weave package).

### Recommended Approach for `claude_code` Package

#### Phase 1: Write Configuration (via config-weave resources)
```bash
# Resource: `claude_code_project_mcp`
# Write to .mcp.json in project root

# Resource: `claude_code_user_mcp`
# Modify ~/.claude.json top-level mcpServers

# Resource: `claude_code_approval`
# Modify ~/.claude.json approval state (if automatable; see below)
```

#### Phase 2: Verification (via gatherer or check resource)

**Gatherer `read_mcp_config`:**
```bash
# Read .mcp.json
cat .mcp.json | jq '.mcpServers | keys'

# Read user-scope servers
jq '.mcpServers // {} | keys' ~/.claude.json

# Read approval state for this project
PROJECT_PATH="$(pwd)"
jq ".projects[\"$PROJECT_PATH\"].enabledMcpjsonServers // []" ~/.claude.json
```

**Resource `test_mcp_connectivity` (optional):**
```bash
# Use CLI to verify connection
claude mcp list | grep -q "✔ Connected"

# Or parse JSON from `get`:
claude mcp get <server-name> | jq '.status'  # (if available)
```

### Challenges for Convergence

| Challenge | Impact | Workaround |
|-----------|--------|-----------|
| Project-scoped approval is interactive | Cannot converge unattended | Accept approval as a manual step; document in README |
| `claude mcp list` output is human-readable | Parsing brittle | Shell wrapper to extract status; or use `get` command and parse JSON |
| No bulk read API | Multiple file reads needed | Parse `.mcp.json` + `~/.claude.json` directly with `jq` |
| Enterprise managed settings (unconfirmed) | Cannot test on regular machines | Avoid assumptions; document architecture when confirmed |

### Example Verification Script

```bash
#!/bin/bash

# Check project-scoped servers exist and are defined
if [ -f .mcp.json ]; then
  EXPECTED="playground github-api"
  ACTUAL=$(jq -r '.mcpServers | keys[]' .mcp.json | sort)
  if [ "$ACTUAL" != "$(echo $EXPECTED | tr ' ' '\n' | sort)" ]; then
    echo "FAIL: .mcp.json servers mismatch"
    exit 1
  fi
fi

# Check user-scope server exists
if ! jq -e '.mcpServers.my-tool // empty' ~/.claude.json > /dev/null; then
  echo "FAIL: User-scope server 'my-tool' not found"
  exit 1
fi

# Check approval state (if automated pre-approval is set up)
PROJECT="$(pwd)"
ENABLED=$(jq -r ".projects[\"$PROJECT\"].enabledMcpjsonServers // []" ~/.claude.json)
if ! echo "$ENABLED" | grep -q "github-api"; then
  echo "WARN: github-api not yet approved in this project"
  # This is expected for project-scope until user approves
fi

echo "PASS: MCP configuration verified"
```

---

## 11. Related Approval Mechanisms: Trust Dialog and External Includes

Beyond MCP approval, Claude Code records approval for two related features in the same `~/.claude.json.projects["/path"]` structure:

### `hasTrustDialogAccepted`
**Purpose:** Indicates user has reviewed and accepted the project for use.

**Key structure:**
```json
{
  "projects": {
    "/home/wil/orca/config-weave-pkgs": {
      "hasTrustDialogAccepted": true
    }
  }
}
```

**When it's set:**
- First time user opens a project in Claude Code
- Shows a "Trust" dialog (similar to GitHub's "Do you trust the authors of this repository?")
- Set to `true` after user clicks "Trust"
- Set to `false` by default for new projects

**What it blocks (if `false`):**
- Unclear from documentation; likely prevents loading certain features until explicitly trusted
- May be a prerequisite for loading `.mcp.json` servers or CLAUDE.md directives

### `hasClaudeMdExternalIncludesApproved` and `hasClaudeMdExternalIncludesWarningShown`
**Purpose:** Tracks approval for external includes in CLAUDE.md files.

**Key structures:**
```json
{
  "projects": {
    "/home/wil/orca/config-weave-pkgs": {
      "hasClaudeMdExternalIncludesApproved": false,
      "hasClaudeMdExternalIncludesWarningShown": true
    }
  }
}
```

**When they're set:**
- `hasClaudeMdExternalIncludesWarningShown`: Set to `true` when Claude Code detects external includes (e.g., `!include https://example.com/file`) in CLAUDE.md
- `hasClaudeMdExternalIncludesApproved`: Set to `true` only after user explicitly approves loading those external files

**What they block:**
- If `false`, external includes in CLAUDE.md are not loaded; user sees a warning in the UI
- Security measure to prevent cloned repos from fetching arbitrary files from the internet without consent

### Implications for Config-Weave Packages

**These fields are similar to MCP approval but less documented.** For a fully converged machine:
- A config-weave package may need to set all three to `true` to enable MCP and CLAUDE.md fully
- Recommended: document which fields the `claude_code` package sets, or leave them to user interaction (accept that trust/approval is a one-time human decision)

---

## 15. Should Approval Have Its Own Typed Resource?

### The Case For a Dedicated Approval Resource

**Observation:** Approval is distinct from server definition.
- `.mcp.json` records "this server is defined"
- `~/.claude.json.projects[path].enabledMcpjsonServers[]` records "user has approved this server"

**If a config-weave package wants unattended convergence, it must write both.** A dedicated approval resource makes this explicit and auditable.

### Proposed Signature

```wcl
resource "claude_code_mcp_approval" "github_api" {
  project_path = "/home/wil/orca/config-weave-pkgs"
  server_name = "github-api"
  approved = true                   # or false to disable/reject
  ensure = :present
}
```

### What Uniquely Identifies an Entry?

**Tuple of `(project_path, server_name)` is the unique key.**
- `project_path`: Absolute filesystem path; must match exactly what Claude Code stores in `~/.claude.json.projects[]`
- `server_name`: User-assigned label in `.mcp.json`
- Together: Maps to membership in `enabledMcpjsonServers[]` or `disabledMcpjsonServers[]` array

**Not recommended:**
- Using URL as identifier (less discoverable; may change)
- Using auto-incrementing IDs (no semantic meaning)

### Implementation Considerations

1. **Path must be exact:** Resource must use the same absolute path that Claude Code would. Recommend:
   ```wcl
   project_path = run("cd $(pwd) && echo $(pwd)").stdout.trim()
   ```

2. **Array management:** Resource writes/removes entry from `enabledMcpjsonServers[]` or `disabledMcpjsonServers[]`:
   ```
   ensure = :present  → add to enabledMcpjsonServers, remove from disabledMcpjsonServers
   ensure = :absent   → remove from both arrays
   approved = false   → add to disabledMcpjsonServers, remove from enabledMcpjsonServers
   ```

3. **Idempotency:** Check if entry already exists in array before writing

### Design Verdict

**YES, a dedicated approval resource is worth having.** Reasons:

1. **Semantic clarity:** Signals that this is distinct from server definition
2. **Convergence completeness:** Caller can see "server defined? approved? converged?"
3. **Auditability:** Changes to approval state are tracked as resource changes, not generic JSON mutations
4. **Security:** Explicit approval resource allows security reviews to check "which servers are auto-approved?"

**The alternative** (embedding approval in `claude_code_mcp_server` resource) is simpler but less discoverable—teams may not realize they need to set `approve_on_converge = true` to get unattended loading.

### Caveat: Path Resolution

**The single failure mode:** If `project_path` doesn't match what Claude Code stores, approval won't apply. Document this clearly:
- Use absolute filesystem paths only
- If project is moved or checked out elsewhere, old approvals don't transfer
- Consider adding a gatherer/check that verifies the path key exists in `~/.claude.json` after resource execution
- For worktrees, resolve through `git rev-parse --show-toplevel` to get the main repo path (if that's what Claude Code uses)

---

## Summary: Key Findings for `claude_code` Package Design

### What We Know (Confirmed)

1. **Unattended approval IS possible:** Config-weave resources can write both `.mcp.json` (server definition) and `~/.claude.json.projects["/path"].enabledMcpjsonServers[]` (approval state) to enable servers silently

2. **Approval is path-keyed:** The project path stored as `.projects["{/absolute/path}"]` key must match exactly where Claude Code resolves the checkout. Path matching logic is not documented; worktree handling is unclear.

3. **Supported transports:** `stdio`, `http`, `sse` (via CLI `claude mcp add --transport`)

4. **Validation is deferred:** `claude mcp add` does not test connectivity at add time; validation happens at session start or when running `claude mcp list`

5. **Enterprise managed settings:** Anthropic documentation refers to managed MCP configuration (unconfirmed on Linux); appears to be separate from regular managed settings but file location and precedence are not verified

6. **Related approvals exist:** `hasTrustDialogAccepted`, `hasClaudeMdExternalIncludesApproved`, and `hasClaudeMdExternalIncludesWarningShown` are similar per-project approval fields; full convergence may require setting all three

### What We Could NOT Confirm (Documented Gaps)

1. **Exact path matching behavior** — whether paths are canonicalized, symlinks resolved, or stored as-is
2. **Worktree path handling** — whether git worktrees store the worktree path or main repo path
3. **What blocks loading** if `hasTrustDialogAccepted` or `hasClaudeMdExternalIncludesApproved` are `false` — semantics not documented
4. **OAuth credential storage format** in `~/.claude.json` — encrypted; not inspectable for structure
5. **Whether enterprise managed MCP has audit logs** — system-admin-only visibility

### Critical Design Constraint

**Path key must match exactly.** If a config-weave resource writes approval to `~/.claude.json.projects["/home/wil/orca/config-weave-pkgs"]` but Claude Code resolves the project as `/home/wil/orca/config-weave-pkgs/` (with trailing slash) or via a symlink, approval will not apply. Document this assumption clearly; test on actual machines to verify.

### Recommended Resource Design

**Three-tier unified approach:**

1. **Project-scope server:** `claude_code_mcp_server` resource
   - Writes to `.mcp.json` with server definition
   - Supported transports: `http`, `sse`, `stdio` (via CLI; `.mcp.json` may support others)
   - Ensure: `:present`, `:absent`
   - Automatically pre-approves if `approve_on_converge: true` is set (writes to `enabledMcpjsonServers[]`)

2. **User-scope server:** Same resource with `scope: "user"` parameter, or separate `claude_code_user_mcp_server`
   - Writes to `~/.claude.json.mcpServers`
   - Auto-loads; no approval needed
   - Available to all projects

3. **Approval state:** Can be embedded in resource above, or use generic key-path resource
   - Writes to `~/.claude.json.projects[path].enabledMcpjsonServers[]` (or `disabledMcpjsonServers[]`)
   - Document: **Pre-writing approval bypasses interactive `/mcp` panel; machine converges with servers loading silently**
   - Caveat: Path key must match exactly what Claude Code resolves for the project

**Example resource:**
```wcl
resource "claude_code_mcp_server" "github_api" {
  scope = "project"                    # "project", "user", or "local"
  server_name = "github-api"
  type = "http"                        # "http", "sse", or "stdio"
  url = "https://api.github.com/v1/mcp"
  env = {
    GH_TOKEN = env("GH_TOKEN")
  }
  approve_on_converge = true           # Pre-approve in enabledMcpjsonServers[]
  ensure = :present
}
```

---

## References

- **Local machine:** Claude Code 2.1.224
- **Configuration files inspected:** `~/.claude.json`, `~/.claude/settings.json`, CLI `--help` output
- **No published Anthropic MCP configuration docs found** (only references from agent-provided documentation)
- **CLI commands verified:** `claude mcp add`, `list`, `get`, `remove`, `reset-project-choices`, `add-json`

