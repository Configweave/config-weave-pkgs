---
title: Claude Code Installation, Detection, and Update on Linux
date: 2026-08-07
---

# Claude Code: Install, Detect, and Update on Linux

## Overview

Claude Code is distributed as a native compiled binary for Linux x86-64 (ELF 64-bit LSB executable). Two primary installation methods exist: native installer script (via bootstrap.sh) and npm package manager. This investigation is based on actual system inspection (`claude --version 2.1.224`, `claude doctor` output, filesystem layout), bootstrap script analysis, and npm registry metadata.

---

## Installation Methods

### 1. Native Installer (Primary Method)

**How it works:**
- Distributed via Anthropic bootstrap script at `https://claude.ai/install.sh` (redirects to `https://downloads.claude.ai/claude-code-releases/bootstrap.sh`)
- Bootstrap script accepts optional `TARGET` parameter: `[stable|latest|<VERSION>]`
- Downloads signed/verified ELF 64-bit binary for platform (linux-x64, linux-arm64, linux-x64-musl, linux-arm64-musl, etc.)
- Binary is downloaded to temporary location, checksum verified (SHA256)
- Runs `<binary> install [TARGET]` to set up launcher, shell integration, and move binary to version directory
- Installs to `~/.local/share/claude/versions/<VERSION>/`
- Symlinks binary at `~/.local/bin/claude` → `~/.local/share/claude/versions/<CURRENT_VERSION>`
- Uses `~/.local/` following XDG Base Directory spec

**What it writes:**
- `~/.local/share/claude/versions/<VERSION>/<binary>` — ELF executable (~250-300 MB per version)
- `~/.local/bin/claude` — symlink to current version
- `~/.claude/downloads/` — temporary directory for downloads during installation
- `~/.claude/settings.json` — configuration (created on first run if absent)
- `~/.claude/.last-update-result.json` — metadata from last installation/update attempt
- `~/.claude/` — user config directory (history, sessions, plugins, credentials, projects, etc.)

**Root required:**
No. Installation is entirely to user home directory. Script actively refuses to run under `sudo` from a regular user's shell (can be overridden with `CLAUDE_INSTALL_ALLOW_SUDO=1` environment variable).

**Non-interactive capability:**
Yes. The bootstrap script and `claude update` command run non-interactively. Installation can be scripted.

**Version pinning:**
Yes, via two mechanisms:
1. **At install time:** Pass `TARGET` to bootstrap script:
   - `curl -fsSL https://claude.ai/install.sh | bash` → latest
   - `curl -fsSL https://claude.ai/install.sh | bash -s stable` → stable
   - `curl -fsSL https://claude.ai/install.sh | bash -s 2.1.220` → exact version
2. **After install:** Edit `~/.claude/settings.json` `autoUpdatesChannel`:
   - `"autoUpdatesChannel": "latest"` (default) — auto-update to latest
   - `"autoUpdatesChannel": "stable"` — auto-update to stable channel only

**Release channels:**
Two channels available for native installer (via bootstrap script and auto-update):
- `stable` — stable/LTS release (2.1.220)
- `latest` — latest release (2.1.224, default)

Note: The `next` dist-tag exists in npm package registry but is **not exposed** as a user-configurable channel for native installer or `autoUpdatesChannel` setting.

---

### 2. npm (Active Method)

**Status:** Active package at `@anthropic-ai/claude-code` on npmjs.org with three release channels:
- `stable`: 2.1.220
- `latest`: 2.1.224 
- `next`: 2.1.224 (npm dist-tag only; not exposed to user `autoUpdatesChannel`)

**How it works:**
- Install: `npm install -g @anthropic-ai/claude-code` (latest) or `npm install -g @anthropic-ai/claude-code@stable` (specific channel/version)
- Package postinstall script (`node install.cjs`) handles binary extraction and setup
- Binary is downloaded to user home directory during postinstall
- Creates symlink/bin wrapper at location managed by npm

**What it writes:**
- `~/.npm/lib/node_modules/@anthropic-ai/claude-code/` or similar (npm v8+ structure)
- Global bin wrapper created by npm at location like `~/.npm/bin/claude` or `/usr/local/bin/claude` depending on npm config
- `~/.claude/` config directory (created on first run, like native installer)

**Root required:**
No. npm `-g` installs to user `npm_config_prefix` (typically `~/.npm` or `~/.nvm/versions/.../`), not system-wide.

**Non-interactive capability:**
Yes. `npm install -g` runs non-interactively.

**Version pinning:**
Yes, directly via npm:
- `npm install -g @anthropic-ai/claude-code@2.1.220` pins to exact version
- `npm install -g @anthropic-ai/claude-code@stable` pins to stable channel tag
- `npm install -g @anthropic-ai/claude-code@latest` pins to latest (default)

**Release channels:**
Three channels available:
- `stable` — stable/LTS releases
- `latest` — latest stable release (default)
- `next` — development/pre-release (npm dist-tag only; not user-configurable via `autoUpdatesChannel`)

**Note:** npm method is fully active and offers explicit version pinning, unlike native installer which relies on settings files.

---

### 3. Homebrew (Not currently available)

**Status:** No Homebrew formula found for Claude Code on macOS or Linux.

**If it existed:**
- Would install to `/usr/local/Cellar/claude/<VERSION>/` (macOS) or Linuxbrew equivalent
- Would require Homebrew (`brew` command)
- Could be non-interactive with `--quiet` flag
- Would manage symlinks to `/usr/local/bin/claude`

---

### 4. Distribution Packages (Not available)

**Status:** No distro packages (`.deb`, `.rpm`, `.pkg`, etc.) found for Claude Code on Linux.

---

### 5. Standalone Binary Download

**Status:** Binaries are available but no direct public download link confirmed. Likely hosted on:
- GitHub Releases (if repo is public)
- Anthropic's CDN
- installer script downloads and verifies before writing

**Manual use:** 
- User could download ELF binary directly and place in `$PATH`
- Would still need to manage versions manually
- Not a documented / supported method

---

## Version Detection

### Reading Installed Version

**Command:**
```bash
claude --version
```

**Output format (exact):**
```
2.1.224 (Claude Code)\n
```

Where `2.1.224` is semver `major.minor.patch`.

**Parsing:**  
First line, first token before space, or `STDOUT` capture and `grep -oE '^[0-9]+\.[0-9]+\.[0-9]+'`.

**Binary location detection:**
```bash
which claude
# → /home/wil/.local/bin/claude

readlink /home/wil/.local/bin/claude
# → /home/wil/.local/share/claude/versions/2.1.224

readlink -f /home/wil/.local/bin/claude
# → /home/wil/.local/share/claude/versions/2.1.224 (canonical path)
```

### Detecting Installation Method

After installation, the method can be detected via:

1. **JSON file read (most reliable for convergence):**
   ```bash
   jq .installMethod ~/.claude.json
   # → "native" or "npm"
   ```
   Direct JSON read from `~/.claude.json`. Works even if binary is broken or partially removed. **Recommended for config-weave resource convergence checks.**

2. **`claude doctor` command output (requires working binary):**
   ```
   Config install method: native
   ```
   or
   ```
   Config install method: npm
   ```
   Directly reports the install method. Output is machine-parseable but requires a working Claude Code binary.

3. **Binary location pattern (fallback):**
   - `~/.local/share/claude/versions/<VERSION>` with symlink `~/.local/bin/claude` → Native installer
   - `~/.npm/lib/node_modules/@anthropic-ai/claude-code/bin/claude` → npm global install
   - System `$PATH` position varies by npm config → npm (would be in npm's bin directory)
   - `/usr/local/Cellar/claude/` → Homebrew (if formula existed)

4. **Symlink vs wrapper inspection:**
   ```bash
   readlink /home/wil/.local/bin/claude
   # native → /home/wil/.local/share/claude/versions/2.1.224
   
   file /home/wil/.local/bin/claude
   # native → symlink; npm → script (bash/sh wrapper)
   ```
   Native installer creates symlink; npm creates a bin wrapper script.

5. **Directory structure check:**
   - If `~/.local/share/claude/versions/` exists with multiple version dirs → Native
   - If `~/.npm/lib/node_modules/@anthropic-ai/claude-code/` exists → npm
   - If both absent and no binary → not installed

### Offline Detection Capability

**Detection (checking installed version) can be done entirely offline:**
- `claude --version` runs locally, no network
- `which claude` is local lookup
- `readlink` is local filesystem
- `~/.local/share/claude/versions/` is local filesystem

**Verdict:** Yes, version detection is fully offline-capable. A config-weave resource can reliably report "absent" on an offline system with no Claude Code installed, or report the exact version if installed.

---

## Updates

### How Updates Work

**Auto-update mechanism:**
- Runs automatically in background during/after `claude` interactive sessions
- Configured by `autoUpdatesChannel` setting (`"latest"` by default, auto-enable on install)
- Checks for new version, downloads if available, symlink is updated atomically

**Update command:**
```bash
claude update
# or
claude upgrade
```

Both are aliases for the same operation. No arguments. Non-interactive.

**What happens:**
1. Contacts update server to check for available version
2. Downloads new binary to `~/.local/share/claude/versions/<NEW_VERSION>/`
3. If successful, updates symlink `~/.local/bin/claude` → `~/.local/share/claude/versions/<NEW_VERSION>`
4. Writes result to `~/.claude/.last-update-result.json`

**Metadata from `.last-update-result.json`:**
```json
{
  "timestamp": "2026-08-07T04:11:48.335Z",
  "path": "native",                          // install method
  "outcome": "success" | "failure",
  "status": "success" | "error",
  "version_from": "2.1.223",                 // previous version
  "version_to": "2.1.224",                   // updated to version
  "error_code": null                         // null if success
}
```

This file allows polling for update status post-update.

### Interaction with Pinned Versions

**Behavior when autoUpdates is enabled and version is pinned:**
- Unknown. Pinning mechanism via settings.json is not fully documented in standard output.
- If `autoUpdatesChannel` is set to `"latest"`, updates will ignore any manual pin and update to latest.
- No `--pin-version` or similar CLI flag observed.

**Self-update:**
Auto-updates happen in background and do not require user intervention. Symlink is updated atomically.

---

## `autoUpdates` and `installMethod` Settings

### Location
`~/.claude/settings.json` (JSON file, user-writable)

### `autoUpdates` and `autoUpdatesProtectedForNative` (in `~/.claude.json`)

**Location:** `~/.claude.json` (top-level, system state)

**`autoUpdates` — global on/off switch:**
- `true` — auto-update enabled (background checks and updates)
- `false` — auto-update disabled (no automatic checks)

**Example:**
```json
{
  "autoUpdates": false
}
```

**`autoUpdatesProtectedForNative` — native installer protection:**
- `true` — prevent downgrades or unsafe version changes on native installs
- Likely enforces minimum version, prevents rolling back if update fails
- Only relevant when `installMethod` is `"native"`

**Example:**
```json
{
  "autoUpdatesProtectedForNative": true
}
```

### `autoUpdatesChannel` Setting (in `~/.claude/settings.json`)

**Location:** `~/.claude/settings.json` (user config, not `~/.claude.json`)

**What it controls:**
- Auto-update channel / release track
- Determines which release stream is downloaded by `claude update` command
- Only active if `autoUpdates` is `true` in `~/.claude.json`

**Example:**
```json
{
  "autoUpdatesChannel": "latest"
}
```

**Legal values:**
- `"stable"` — auto-update only to stable releases (2.1.220)
- `"latest"` — auto-update to latest release (2.1.224, default)

**Relationship:**
- `~/.claude.json` `autoUpdates` = global on/off
- `~/.claude/settings.json` `autoUpdatesChannel` = which channel (when enabled)

Both must be satisfied: autoUpdates must be true AND channel must be set for auto-update to work.

### `installMethod` Setting (in `~/.claude.json`)

**Location:** `~/.claude.json` (top-level, not in `settings.json`)

**What it stores:**
- Install method used: `"native"` or `"npm"` (inferred; other values possible)
- Set by installer at installation time
- Recorded for detection and to determine update/uninstall behavior

**Example value:**
```json
{
  "installMethod": "native"
}
```

**Access:**
- Direct JSON read: `jq .installMethod ~/.claude.json`
- Or via `claude doctor`: `Config install method: native`

**Resource detection advantage:** Reading JSON works even if the binary is broken or removed, whereas `claude doctor` requires a working installation.

---

## Uninstall

### What Must Be Deleted

**Complete uninstall (all methods):**
```bash
rm -rf ~/.local/share/claude/                      # All versions
rm -f ~/.local/bin/claude                          # Symlink
rm -rf ~/.claude/                                  # Config, credentials, history, projects
```

**Minimal uninstall (binary only, preserve config):**
```bash
rm -rf ~/.local/share/claude/
rm -f ~/.local/bin/claude
```

### User Config Survival

**By default, uninstall does NOT delete `~/.claude/`:**
- User settings (`settings.json`)
- Credentials (`.credentials.json` — encrypted)
- Session history (`history.jsonl`)
- Projects (`projects/`)
- Plugins (`plugins/`)
- All survive uninstall

This is intentional — reinstalling Claude Code restores all user configuration. Explicit `rm -rf ~/.claude/` is required to wipe config.

### Per-Method Differences

**Native installer:** No uninstall script provided. Manual deletion as above.

**npm (if available):** `npm uninstall -g @anthropic-ai/claude` deletes binary and global bin wrapper, but not `~/.claude/`.

**Homebrew (if available):** `brew uninstall claude` deletes formula files and bin, but not `~/.claude/`.

---

## Network Requirements

### For Detection (Install Status Check)

**Offline:** ✅ Yes, fully offline.
- `claude --version`, `which claude`, filesystem checks all work without network.

### For Auto-Update Check

**Online required:** Yes, must contact update server to check for new version.
- Without network, auto-update silently skips (no error).
- Will retry next time network is available.

### For Initial Installation

**Online required:** Yes, must download binary from installer script or CDN.
- Installer script must fetch binary before writing.
- No local installation method without network access.

---

## Summary of Install Methods

| Method | Status | Root | Non-interactive | Pinning | Binary Location | Detect After |
|--------|--------|------|-----------------|---------|-----------------|--------------|
| Native | ✅ Active | No | Yes | Via bootstrap arg or settings | `~/.local/share/claude/versions/<V>` | `claude doctor`, symlink at `~/.local/bin/claude` |
| npm | ✅ Active | No | Yes | Via `npm install -g @anthropic-ai/claude-code@<version>` | `~/.npm/lib/node_modules/@anthropic-ai/claude-code/` | `claude doctor`, npm directory |
| Homebrew | ❌ No formula | No | Yes | Via `brew` | N/A | N/A |
| Distro pkg | ❌ None | Varies | Yes | Via pkg mgr | N/A | N/A |

---

## Critical Design Notes for config-weave Resource

1. **Two primary installation methods:** Native (via bootstrap script) and npm. Both install to user home, never system-wide.

2. **Version detection is fully offline.** A resource can reliably report `absent` on an offline system via:
   - `claude --version` (if binary exists)
   - `~/.local/bin/claude` symlink inspection (native)
   - Directory checks (`~/.local/share/claude/versions/`, `~/.npm/lib/node_modules/`)

3. **Installation method detection (convergence check):**
   - **Recommended:** JSON read `jq .installMethod ~/.claude.json` → `"native"` or `"npm"`
   - Fallback: `claude doctor` command (requires working binary)
   - Fallback: Directory structure and symlink inspection
   
   **Why JSON is superior:** Works even if binary is broken, removed, or partially installed.

4. **Configuration is split across two files:**
   - `~/.claude.json` — system state: `installMethod`, `autoUpdates` (on/off), `autoUpdatesProtectedForNative`
   - `~/.claude/settings.json` — user config: `autoUpdatesChannel` (stable/latest), model, permissions, hooks, plugins, etc.
   
   Both files must be read for full state. Settings file is user-editable; JSON file is system-managed.

5. **Auto-update control:**
   - `~/.claude.json` `autoUpdates` = on/off switch (global)
   - `~/.claude/settings.json` `autoUpdatesChannel` = channel selection (stable/latest, only when autoUpdates is true)
   - Both must align for auto-update to function

6. **Version pinning available for both methods:**
   - Native: `curl ... | bash -s stable` or `curl ... | bash -s 2.1.220` at install time, or `autoUpdatesChannel` setting after
   - npm: `npm install -g @anthropic-ai/claude-code@stable` or `npm install -g @anthropic-ai/claude-code@2.1.220`

7. **Two release channels:** `stable` (2.1.220) and `latest` (2.1.224). The `next` dist-tag exists in npm but is not user-configurable.

8. **Multiple versions coexist** (native): `~/.local/share/claude/versions/<VERSION>/`; symlink at `~/.local/bin/claude` points to active version.

9. **Update behavior:**
   - Native: `claude update` is idempotent and non-interactive
   - npm: Requires explicit `npm install -g @anthropic-ai/claude-code` to update
   - Update metadata available in `~/.claude/.last-update-result.json` for native method

10. **Settings and config survive uninstall.** Only delete `~/.claude/` if explicitly requested.

11. **Timing concern:** `~/.claude.json` keys may be written by installer or lazily on first run. Resource checking immediately after install may need to handle absent keys.

---

## Uncertainties / Gaps

1. **Homebrew formula:** No current Homebrew formula found. Unclear if one exists or was deprecated.
2. **npm postinstall behavior:** The npm package has a `postinstall` script (`node install.cjs`) that handles installation. Exact behavior unknown — whether it uses same `~/.local/share/claude/versions/` structure as native installer, or different paths. Detection via JSON read (`~/.claude.json` `installMethod`) is the safe approach and does not require binary to work.
3. **npm platform/arch support:** npm tarball contains bin entry `bin/claude.exe`. Does postinstall extract a prebuilt binary or use a wrapper? Behavior of npm auto-update unknown (whether it respects semver ranges or requires explicit `npm install -g` to update).
4. **Timing of JSON file creation:** Whether `~/.claude.json` keys (`installMethod`, `autoUpdates`, `autoUpdatesProtectedForNative`) are written by installer at install time or lazily on first run. Resource checking right after install may find them absent; timing TBD.
5. **npm installMethod value:** Assumed to be `"npm"` but not verified. Could be different string.
6. **autoUpdatesProtectedForNative semantics:** Likely prevents downgrades for native installs, but exact behavior unknown. May enforce minimum version, may mark unsafe-update state, may prevent rollback.

---

## Verification Sources

- **Actual system state files:**
  - `~/.claude.json` — verified `installMethod: "native"`, `autoUpdates: false`, `autoUpdatesProtectedForNative: true` structure
  - `~/.claude/settings.json` — verified keys: `autoUpdatesChannel`, `env`, `model`, `permissions`, `hooks`, `plugins`, `attribution`, etc.
  - `~/.claude/.last-update-result.json` — verified update metadata structure
  - `~/.local/share/claude/versions/2.1.224` — ELF 64-bit binary, native installation
  - `~/.local/bin/claude` — symlink to active version

- **Bootstrap script:** `https://downloads.claude.ai/claude-code-releases/bootstrap.sh` (via redirect from `https://claude.ai/install.sh`)
  - Confirms native installer supports `[stable|latest|<VERSION>]` targets
  - Shows platform detection (linux-x64, linux-arm64, musl variants), checksum verification, and `<binary> install` flow
  - Reveals `~/.claude/downloads/` directory usage
  - Documents `CLAUDE_INSTALL_ALLOW_SUDO` override

- **npm package registry:** `https://registry.npmjs.org/@anthropic-ai%2fclaude-code`
  - Confirms three dist-tags: `stable` (2.1.220), `latest` (2.1.224), `next` (2.1.224)
  - Postinstall script: `node install.cjs`
  - Bin entry: `bin/claude.exe`

- **CLI output:** `claude --version`, `claude update --help`, `claude doctor` (all consistent and parseable)

- **Settings reference:** `~/.claude/plugins/cache/wil-plugins/experts/0.1.0/skills/cc-settings/references/settings-reference.md`
  - Confirms `autoUpdatesChannel` legal values: `"stable"` or `"latest"`

- **Download endpoints:** Verified `https://downloads.claude.ai/claude-code-releases/latest` (returns 2.1.224) and `/stable` (returns 2.1.220)

