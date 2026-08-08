# 07 — Settings key audit: #9's table vs. the Claude Code binary

**Question ([#18](https://github.com/Configweave/config-weave-pkgs/issues/18)):**
does #9's settings key table actually cover the settings surface, and what is
missing?

**Source:** the Claude Code CLI binary at
`~/.local/share/claude/versions/2.1.225` (297 831 432 bytes, installed
2026-08-08), with `2.1.223` and `2.1.224` used for version cross-checks.
Documentation was read last and only to classify the documented-but-dead set.

> **Provenance.** This file overwrites an unreviewed draft left by an earlier
> run. Every number and offset below was re-derived independently. The draft's
> three headline figures (155 / 56 / 99) reproduced exactly; a section at the
> end lists the places where this audit **overturns or extends** it.

## Headline

| | |
|---|---|
| Settings keys the binary carries | **155** |
| Of those, placed by #9's table (after #13's and #12's corrections) | **56** |
| **Missing from the table** | **99** |
| **Phantom** — named in the table, not a settings key in the binary | **15** named + **3** uncounted `allowManaged*Only` slots |
| Documented on the settings page, absent from every binary checked | **3** |
| Documented on the settings page but `~/.claude.json` keys, not `settings.json` keys | **6** |

**A new section resource is needed — seven of them.** The inventory cannot stay
at 30 resources and 2 gatherers. Routing all 99 missing keys onto the existing
13 would give `ui` 40 params and `managed_policy` 19. The recommendation is
**13 → 20 section resources** plus one new element-level resource, taking the
inventory to **38 resources and 2 gatherers** — or **41** if the `sandbox`
split below is also taken.

**Two of #9's existing resources are built mostly on keys that do not exist.**
`subagents` listed 8 keys; **5 are phantom** (`subagentModel`,
`subagentToolRestrictions`, `subagentPermissionMode`, `maxConcurrentSubagents`,
`maxSubagentSpawnDepth`) and a 6th (`agents`) is not a settings key. `sandbox`
listed 4 leaves; the real object has **15 members and roughly 40 leaves**.

## How the enumeration was recovered

The settings schema is a single contiguous object literal. Three independent
reads, which agree:

1. **The zod schema builder.** `grep -a -o -b 'function lns(e){return Se({$schema:'`
   lands at byte **268 738 931**. Its first field is
   `$schema:$().optional().describe("JSON Schema reference for Claude Code settings")`,
   so this is `settings.json` and nothing else. Balancing braces, strings and
   parens from that point, the literal ends at byte **268 776 871** with
   `}).passthrough()` — **37 940 bytes**, splitting into **152 top-level
   segments**: 148 named keys (including `$schema`), two dead spreads (`...!1`),
   one conditional spread (`...te.CLAUDE_CODE_ENABLE_XAA&&{xaaIdp:…}`) and one
   live spread (`...VIc(e)`).
2. **The feature-gated spread.** The live schema is
   `iV=Ee(()=>lns(Qrs()))`, where `Qrs(){return gUg.filter((e)=>Nlo[e].buildGate())}`
   (byte **268 726 298**). `VIc` at byte **268 726 394** merges `Nlo[r].shape()`
   for `gUg=["autoMode","deepLink","voice","briefView","screenReader"]` (byte
   **268 726 687**). All five gates read `buildGate:()=>!0`, verified by
   extracting the `Nlo` literal (2 379 bytes) and grepping it — five hits, all
   `!0` — so all five contribute unconditionally: `skipAutoPermissionPrompt`,
   `useAutoModeDuringPlan`, `autoMode`, `disableDeepLinkRegistration`,
   `voiceEnabled`, `defaultView`, `axScreenReader`. A sibling spread `KIc` adds
   `disableAutoMode` **inside** `permissions`.
3. **The V8 heap string table** at bytes **100 948 636 –** — the run #12 saw.
   Layout is `<len:u32> <chars>` records; the first six entries read `$schema`,
   `apiKeyHelper`, `proxyAuthHelper`, `awsCredentialExport`, `awsAuthRefresh`,
   `gcpAuthRefresh` — schema declaration order exactly. Used as the check that
   no top-level key was lost to a parse error, and as the grouping evidence
   cited below.

147 named keys (148 minus `$schema`, which is a JSON Schema pointer rather than
a setting) + `xaaIdp` + 7 from `VIc` = **155**. `xaaIdp` is conditional on
`CLAUDE_CODE_ENABLE_XAA`.

### Unknown keys are retained, and there are two validation paths

The loader path is `cns` (byte **268 777 090**, 8 180 bytes): it rebuilds the
shape with a per-field `.catch()` that drops only the offending field with a
warning, then returns **`Se(n).passthrough()`**. So an unrecognised key is
**retained, not stripped**, which sharpens #9's argument for the generic
`setting` escape hatch — and means a typo in a typed param's key name would
converge green forever.

The *validating* path is different: `kUg=Ee(()=>iV().strict())`, consumed by
`dns(e)`, and the error formatter has a dedicated `unrecognized_keys` branch
producing `` `Unrecognized ${It(r.keys.length,"field")}: ${d}` ``. Both facts
matter to the package: writing an unknown key is silently tolerated at runtime
but surfaces as an error in explicit validation.

## Complete key table

Every row is read from the schema literal cited above; nested objects are one
row, with leaf counts in the analysis that follows. Minifier aliases:
`Ut()` = boolean, `$()` = string, `at()` = number, `dt(X)` = array,
`Wn(K,V)` = map, `Se({})` = object, `$r([…])` = enum, `fs([…])` = union,
`Fv(f,X)` = coerced union, `xt(v)` = literal.

| # | Key | Type | Section resource (per #9 naming) | Status |
|---:|---|---|---|---|
| 1 | `apiKeyHelper` | string | `auth` | in table |
| 2 | `proxyAuthHelper` | string | `auth` | in table |
| 3 | `awsCredentialExport` | string | `auth` | in table |
| 4 | `awsAuthRefresh` | string | `auth` | in table |
| 5 | `gcpAuthRefresh` | string | `auth` | in table |
| 6 | `processWrapper` | string | `auth` | **missing** |
| 7 | `policyHelper` | object `{path,timeoutMs,refreshIntervalMs}` | `managed_policy` | **missing** |
| 8 | `xaaIdp` | object | `mcp_settings` | in table |
| 9 | `fileSuggestion` | object | `ui` | **missing** |
| 10 | `respectGitignore` | bool | `ui` | **missing** |
| 11 | `breakReminder` | object | `ui` | **missing** |
| 12 | `quietHours` | object | `ui` | **missing** |
| 13 | `cleanupPeriodDays` | number | `context` | **missing** |
| 14 | `skillListingMaxDescChars` | number | **`skills`** (new) | **missing** |
| 15 | `skillListingBudgetFraction` | number | **`skills`** (new) | **missing** |
| 16 | `wslInheritsWindowsSettings` | bool | `managed_policy` | **missing** |
| 17 | `env` | map<string,string> | `env_var` (element) | in table |
| 18 | `attribution` | object | `attribution` | in table |
| 19 | `includeCoAuthoredBy` | bool | `attribution` | in table |
| 20 | `includeGitInstructions` | bool | `attribution` | **missing** |
| 21 | `permissions` | object (7 leaves) | `permissions` | in table |
| 22 | `model` | string | `model` | in table |
| 23 | `fallbackModel` | array | `model` | in table |
| 24 | `availableModels` | array | `model` | in table |
| 25 | `enforceAvailableModels` | bool | `model` | **missing** |
| 26 | `modelOverrides` | map | `model` | in table |
| 27 | `enableAllProjectMcpServers` | bool | `mcp_settings` | in table |
| 28 | `enabledMcpjsonServers` | array | `mcp_server` (element) | in table |
| 29 | `disabledMcpjsonServers` | array | `mcp_server` (element) | in table |
| 30 | `disableClaudeAiConnectors` | bool | `mcp_settings` | in table |
| 31 | `skillOverrides` | map | **`skills`** (new) | **missing** |
| 32 | `disableBundledSkills` | bool | **`skills`** (new) | **missing** |
| 33 | `allowedMcpServers` | array | `mcp_settings` | in table |
| 34 | `deniedMcpServers` | array | `managed_policy` | in table |
| 35 | `hooks` | object | `hook` (element) | in table |
| 36 | `worktree` | object | **`worktree`** (new) | **missing** |
| 37 | `disableAllHooks` | bool | **`hook_policy`** (new) | **missing** |
| 38 | `disableAgentView` | bool | `subagents` | **missing** |
| 39 | `disableRemoteControl` | bool | `remote_control` | **missing** |
| 40 | `disableWorkflows` | bool | **`workflows`** (new) | **missing** |
| 41 | `disableArtifact` | bool | **`features`** (new) | **missing** |
| 42 | `enableArtifact` | bool | **`features`** (new) | **missing** |
| 43 | `enableWorkflows` | bool | **`workflows`** (new) | **missing** |
| 44 | `workflowSizeGuideline` | enum `["unrestricted","small","medium","large"]` | **`workflows`** (new) | in table |
| 45 | `workflowKeywordTriggerEnabled` | bool | **`workflows`** (new) | **missing** |
| 46 | `disableSkillShellExecution` | bool | **`skills`** (new) | **missing** |
| 47 | `defaultShell` | enum `["bash","powershell"]` | `ui` | **missing** |
| 48 | `respondToBashCommands` | bool | `ui` | **missing** |
| 49 | `allowManagedHooksOnly` | bool | `managed_policy` | in table |
| 50 | `allowedHttpHookUrls` | array | **`hook_policy`** (new) | **missing** |
| 51 | `httpHookAllowedEnvVars` | array | **`hook_policy`** (new) | **missing** |
| 52 | `allowManagedPermissionRulesOnly` | bool | `managed_policy` | in table |
| 53 | `allowManagedMcpServersOnly` | bool | `managed_policy` | in table |
| 54 | `allowAllClaudeAiMcps` | bool | `mcp_settings` | **missing** |
| 55 | `strictPluginOnlyCustomization` | union bool \| array `["skills","agents","hooks","mcp"]` | `managed_policy` | **missing** |
| 56 | `statusLine` | object | **`status_line`** (new) | in table |
| 57 | `prUrlTemplate` | string | `ui` | **missing** |
| 58 | `footerLinksRegexes` | array | `ui` | **missing** |
| 59 | `subagentStatusLine` | object | **`status_line`** (new) | **missing** |
| 60 | `enabledPlugins` | map | `plugin` (element) | in table |
| 61 | `extraKnownMarketplaces` | map | `marketplace` (element) | in table |
| 62 | `strictKnownMarketplaces` | array | `managed_policy` | in table |
| 63 | `blockedMarketplaces` | array | `managed_policy` | in table |
| 64 | `disableSideloadFlags` | bool | `managed_policy` | in table |
| 65 | `pluginSuggestionMarketplaces` | array | `managed_policy` | **missing** |
| 66 | `forceLoginMethod` | enum `["claudeai","console","gateway"]` | `auth` | in table |
| 67 | `forceLoginGatewayUrl` | string | `auth` | in table |
| 68 | `parentSettingsBehavior` | enum `["first-wins","merge"]` | `managed_policy` | **missing** |
| 69 | `forceLoginOrgUUID` | union string \| array<string> | `auth` | in table |
| 70 | `forceRemoteSettingsRefresh` | bool | `managed_policy` | in table |
| 71 | `otelHeadersHelper` | string | `auth` | **missing** |
| 72 | `outputStyle` | string | `ui` | in table |
| 73 | `viewMode` | enum `["default","verbose","focus"]` | `ui` | **missing** |
| 74 | `language` | string | `ui` | **missing** |
| 75 | `skipWebFetchPreflight` | bool | **`features`** (new) | **missing** |
| 76 | `sandbox` | object (15 members, ~40 leaves) | `sandbox` | in table |
| 77 | `feedbackSurveyRate` | number | `ui` | **missing** |
| 78 | `feedbackDrafts` | enum `["notify","quiet","off"]` | `ui` | **missing** |
| 79 | `spinnerTipsEnabled` | bool | `ui` | **missing** |
| 80 | `spinnerVerbs` | object | `ui` | **missing** |
| 81 | `spinnerTipsOverride` | object | `ui` | **missing** |
| 82 | `syntaxHighlightingDisabled` | bool | `ui` | **missing** |
| 83 | `terminalTitleFromRename` | bool | `ui` | **missing** |
| 84 | `alwaysThinkingEnabled` | bool | `model` | in table |
| 85 | `effortLevel` | enum `["low","medium","high","xhigh"]` | `model` | in table |
| 86 | `ultracode` | bool | **`workflows`** (new) | **missing** |
| 87 | `autoCompactWindow` | number | `context` | in table |
| 88 | `advisorModel` | string | `model` | **missing** |
| 89 | `fastMode` | bool | `model` | **missing** |
| 90 | `fastModePerSessionOptIn` | bool | `model` | **missing** |
| 91 | `promptSuggestionEnabled` | bool | `ui` | **missing** |
| 92 | `emojiCompletionEnabled` | bool | `ui` | in table |
| 93 | `awaySummaryEnabled` | bool | `context` | in table |
| 94 | `showClearContextOnPlanAccept` | bool | `ui` | **missing** |
| 95 | `askUserQuestionTimeout` | enum `["60s","5m","10m","never"]` | `ui` | **missing** |
| 96 | `dialogExpiry` | enum `["60s","5m","10m","never"]` | `remote_control` | **missing** |
| 97 | `agent` | string | `subagents` | in table |
| 98 | `companyAnnouncements` | array | `ui` | **missing** |
| 99 | `pluginConfigs` | map | `plugin` (element) | in table |
| 100 | `remote` | object | `remote_control` | **missing** |
| 101 | `autoUpdatesChannel` | enum `["latest","stable","rc"]` | `auto_update` | in table |
| 102 | `minimumVersion` | string | `auto_update` | **missing** |
| 103 | `requiredMinimumVersion` | string | `managed_policy` | **missing** |
| 104 | `requiredMaximumVersion` | string | `managed_policy` | **missing** |
| 105 | `plansDirectory` | string | `context` | **missing** |
| 106 | `tui` | enum `["default","fullscreen"]` | `ui` | **missing** |
| 107 | `voice` | object | `ui` | **missing** |
| 108 | `channelsEnabled` | bool | `managed_policy` | in table |
| 109 | `allowedChannelPlugins` | array | `managed_policy` | **missing** |
| 110 | `prefersReducedMotion` | bool | `ui` | **missing** |
| 111 | `doneMeansMerged` | bool | **`features`** (new) | **missing** |
| 112 | `totalTokensReminder` | enum `["off","infinite","fixed","countdown","padded-countdown"]` | `context` | **missing** |
| 113 | `totalTokensReminderBudget` | number | `context` | **missing** |
| 114 | `totalTokensReminderAfterUserTurn` | bool | `context` | **missing** |
| 115 | `autoMemoryEnabled` | bool | `context` | in table |
| 116 | `autoMemoryDirectory` | string | `context` | **missing** |
| 117 | `autoDreamEnabled` | bool | `context` | **missing** |
| 118 | `showThinkingSummaries` | bool | `ui` | **missing** |
| 119 | `skipDangerousModePermissionPrompt` | bool | `permissions` | in table |
| 120 | `skipWorkflowUsageWarning` | bool | **`workflows`** (new) | **missing** |
| 121 | `disableAutoMode` | enum `["disable"]` | `auto_mode` | **missing** |
| 122 | `sshConfigs` | array | **`ssh_config`** (new, element) | **missing** |
| 123 | `claudeMd` | string | `managed_policy` | in table |
| 124 | `claudeMdExcludes` | array | `context` | **missing** |
| 125 | `pluginTrustMessage` | string | `managed_policy` | **missing** |
| 126 | `theme` | union (enum+`custom:` prefix) | `ui` | in table |
| 127 | `editorMode` | enum `["normal","vim"]` | `ui` | in table |
| 128 | `vimInsertModeRemaps` | map | `ui` | **missing** |
| 129 | `verbose` | bool | `ui` | in table |
| 130 | `preferredNotifChannel` | enum (7: auto, iterm2, terminal_bell, iterm2_with_bell, kitty, ghostty, notifications_disabled) | **`notifications`** (new) | **missing** |
| 131 | `autoCompactEnabled` | bool | `context` | in table |
| 132 | `precomputeCompactionEnabled` | bool | `context` | **missing** |
| 133 | `switchModelsOnFlag` | bool | `model` | **missing** |
| 134 | `autoScrollEnabled` | bool | `ui` | **missing** |
| 135 | `wheelScrollAccelerationEnabled` | bool | `ui` | **missing** |
| 136 | `fileCheckpointingEnabled` | bool | **`features`** (new) | **missing** |
| 137 | `showTurnDuration` | bool | `ui` | **missing** |
| 138 | `showMessageTimestamps` | bool | `ui` | **missing** |
| 139 | `terminalProgressBarEnabled` | bool | `ui` | **missing** |
| 140 | `todoFeatureEnabled` | bool | `ui` | **missing** |
| 141 | `teammateMode` | enum `["auto","tmux","iterm2","in-process"]` | `subagents` | **missing** |
| 142 | `remoteControlAtStartup` | bool | `remote_control` | in table |
| 143 | `isolatePeerMachines` | bool | `remote_control` | **missing** |
| 144 | `daemonColdStart` | enum `["transient","ask"]` | `remote_control` | **missing** |
| 145 | `crossSessionInbound` | enum `["accept","hold","refuse"]` | `remote_control` | **missing** |
| 146 | `autoUploadSessions` | bool | `remote_control` | **missing** |
| 147 | `inputNeededNotifEnabled` | bool | **`notifications`** (new) | **missing** |
| 148 | `agentPushNotifEnabled` | bool | **`notifications`** (new) | **missing** |
| 149 | `skipAutoPermissionPrompt` | bool | `auto_mode` | **missing** |
| 150 | `useAutoModeDuringPlan` | bool | `auto_mode` | **missing** |
| 151 | `autoMode` | object | `auto_mode` | in table |
| 152 | `disableDeepLinkRegistration` | enum `["disable"]` | **`features`** (new) | **missing** |
| 153 | `voiceEnabled` | bool | `ui` | **missing** |
| 154 | `defaultView` | enum `["chat","transcript"]` | `ui` | **missing** |
| 155 | `axScreenReader` | bool | `ui` | in table |
## The 99 missing keys, by assigned resource

### Onto existing section resources — 59

| Resource | Keys it gains | Note |
|---|---|---|
| `model` (6 → 11) | `enforceAvailableModels`, `advisorModel`, `fastMode`, `fastModePerSessionOptIn`, `switchModelsOnFlag` | `enforceAvailableModels` is the enforcement half of `availableModels` and is meaningless apart from it — *"When true and availableModels is a non-empty array, the Default model selection is also constrained"*. The loader treats an invalid value as `true` (`'"enforceAvailableModels" was present but invalid; treating it as true until it is fixed.'`, inside `cns`). Splitting the pair across resources would let a playbook set an allowlist that does not bind. |
| `context` (4 → 13) | `precomputeCompactionEnabled`, `autoMemoryDirectory`, `autoDreamEnabled`, `cleanupPeriodDays`, `plansDirectory`, `claudeMdExcludes`, `totalTokensReminder`, `totalTokensReminderBudget`, `totalTokensReminderAfterUserTurn` | The three `totalTokensReminder*` keys are marked `@internal` and *"Server-controlled via GrowthBook"* — type them, document them as unsupported. `autoMemoryDirectory` is *"Ignored if set in projectSettings (checked-in .claude/settings.json) for security"*, so it is a wrong-scope validation error at `:project`. `claudeMdExcludes` is placed here **uncertainly** — see below. |
| `ui` (7 → 40) | see table | **Too large.** Even after the seven-way split below, `ui` still carries 33 keys. It is the resource most in need of a further split, and this audit does not propose one because no defensible seam presents itself — they really are all "the terminal UI". |
| `auto_mode` (4 → 8) | `autoMode.classifyAllShell`, `skipAutoPermissionPrompt`, `useAutoModeDuringPlan`, top-level `disableAutoMode` | Two findings here. #9's table names four `autoMode` leaves; the object has **five** — `allow`, `soft_deny`, `hard_deny`, `environment`, **`classifyAllShell`**. And **`disableAutoMode` exists twice**: once top-level (schema segment 121) and once inside `permissions` via `KIc`, both `$r(["disable"]).optional().describe("Disable auto mode")`. That needs two params, or one param that writes both — a design decision, not a research one. |
| `subagents` (8 → 3) | `teammateMode`, `disableAgentView` | 5 of its 8 original keys are phantom. It survives with `agent`, `teammateMode`, `disableAgentView` — and `agent` is arguably `model`'s (*"Applies the agent's system prompt, tool restrictions, and model"*). Recommend renaming to **`teammates`** or dissolving it. Note `disableAgentView` is about **background** agents (*"`claude agents`, `--bg`, /background, the on-demand daemon"*), which is nearer `remote_control` than teammates — flagged as uncertain. |
| `auth` (8 → 10) | `processWrapper`, `otelHeadersHelper` | Both command-valued, so #10's rule for `apiKeyHelper` applies unchanged. `processWrapper` is *"Honored from managed settings, a --settings/SDK-supplied settings file, and user settings, in that precedence order; project and local settings are ignored"* — a wrong-scope validation error per #10. |
| `attribution` (2 → 3) | `includeGitInstructions` | The ticket's key. `Ut()`, *"Include built-in commit and PR workflow instructions in Claude's system prompt (default: true)"*. It sits directly between `includeCoAuthoredBy` and `permissions` in the schema — adjacent to the other two attribution keys, exactly the grouping signal #18 asked for. `attribution` also has a **third leaf** the table missed: `sessionUrl` (bool), alongside `commit` and `pr`. |
| `mcp_settings` (5 → 6) | `allowAllClaudeAiMcps` | *"When true (and set in managed settings) … Read from managed settings only."* — so `managed_policy` has a claim; kept here because it is meaningless without the claude.ai connector keys beside it. |
| `remote_control` (2 → 8) | `disableRemoteControl`, `isolatePeerMachines`, `daemonColdStart`, `crossSessionInbound`, `autoUploadSessions`, `dialogExpiry`, `remote.defaultEnvironmentId` | `dialogExpiry`'s own description is about dialogs *"forwarded to a remote client"* and HELD cross-session messages, and it is *"Read from trusted sources only (never a checked-in repo settings file)"* — a wrong-scope error at `:project`. |
| `managed_policy` (17 → 19) | `policyHelper`, `parentSettingsBehavior`, `wslInheritsWindowsSettings`, `requiredMinimumVersion`, `requiredMaximumVersion`, `pluginTrustMessage`, `pluginSuggestionMarketplaces`, `allowedChannelPlugins`, `strictPluginOnlyCustomization` | It gains 9 and loses 7 (5 phantom + 2 dead), netting 19. Each of the nine carries an explicit managed-only gate in its own description, so #9's `scope = :enterprise` fixing holds for all nine. |
| `auto_update` (1 → 2) | `minimumVersion` | `minimumVersion` has **no** managed gate (*"Minimum version to stay on - prevents downgrades when switching to stable channel"*), unlike `requiredMinimumVersion` / `requiredMaximumVersion`, which both say *"Only enforced from managed (policy) settings"*. Same-sounding names, different scope rules — a docs hazard worth calling out on both resources. |
| `permissions` | — | Already placed, but the leaf count is **7**, not #9's implied 4: `allow`, `deny`, `ask`, `defaultMode`, `disableBypassPermissionsMode`, `disableAutoMode` (via `KIc`), `additionalDirectories`. `defaultMode` accepts `nAe=["acceptEdits","auto","bypassPermissions","default","dontAsk","plan"]` plus gate-contributed modes, with `'manual'` as an alias for `default`. |

### Onto seven new section resources — 39

| New resource | Keys | Why it is not a param on an existing one |
|---|---|---|
| **`status_line`** (7 params) | `statusLine.{type,command,padding,refreshInterval,hideVimModeIndicator}`, `subagentStatusLine.{type,command}` | #9 put `statusLine` on `ui` as one param. It is **not** free-form: `Se({type:xt("command"),command:$(),padding:at().optional(),refreshInterval:at().min(1)…,hideVimModeIndicator:Ut()…})`. A map param would hide a fixed schema, which #9's own "free-form objects stay typed" rule reserves for objects that have *no* schema. `subagentStatusLine` is the same shape and belongs beside it. The doc cell must cross-reference `disableAllHooks`, whose description is *"Disable all hooks **and statusLine execution**"*. |
| **`skills`** (5) | `skillOverrides`, `skillListingMaxDescChars`, `skillListingBudgetFraction`, `disableBundledSkills`, `disableSkillShellExecution` | A coherent theme with no owner. #9's inventory has a `skill` *content* resource that writes skill files; nothing configures how skills are listed and executed. `skillOverrides` is `Wn($(),$r(["on","name-only","user-invocable-only","off"]))` — a map from skill name to a four-value symbol, so `skill`'s own docs cannot explain it either. |
| **`workflows`** (6) | `enableWorkflows`, `disableWorkflows`, `workflowSizeGuideline`, `workflowKeywordTriggerEnabled`, `ultracode`, `skipWorkflowUsageWarning` | `workflowSizeGuideline` was `subagents`' only surviving non-phantom key besides `agent`. The other five arrive with it in the binary's own contiguous run (`disableWorkflows … enableWorkflows … workflowSizeGuideline … workflowKeywordTriggerEnabled`, schema segments 40–45). `ultracode` belongs here rather than on `model`: *"xhigh effort plus standing dynamic-workflow orchestration … Requires workflows to be enabled and an xhigh-capable model."* |
| **`worktree`** (4) | `worktree.{symlinkDirectories,sparsePaths,baseRef,bgIsolation}` | A fixed-schema nested object with four typed leaves, two of them enums (`baseRef`: `fresh`/`head`; `bgIsolation`: `worktree`/`none`). Nothing in #9's inventory is about git worktrees. The public docs give it its own "Worktree settings" section, which is corroboration rather than the source. |
| **`notifications`** (3) | `preferredNotifChannel`, `inputNeededNotifEnabled`, `agentPushNotifEnabled` | `preferredNotifChannel` is a 7-value enum (`Sce=["auto","iterm2","terminal_bell","iterm2_with_bell","kitty","ghostty","notifications_disabled"]`); the other two are mobile push. Contiguous at the very end of the schema. Thin, and could fold into `ui` — flagged as the weakest of the seven. |
| **`features`** (6) | `disableArtifact`, `enableArtifact`, `disableDeepLinkRegistration`, `fileCheckpointingEnabled`, `skipWebFetchPreflight`, `doneMeansMerged` | The leftover product on/off switches, each with no other subject-owner. Not an invented grouping: the binary carries them as a run of `disable*`/`enable*` keys at schema segments 37–46. Crucially these are **not** managed-only — `disableAgentView` and `disableRemoteControl` say *"Typically set in managed settings"*, not *"when set in managed settings"* — so they cannot go on `managed_policy`, whose `scope` #9 fixed to `:enterprise`. |
| **`hook_policy`** (3) | `disableAllHooks`, `allowedHttpHookUrls`, `httpHookAllowedEnvVars` | #15 handed `disableAllHooks` to this ticket and asked that `hook`'s doc cell cross-reference it. It cannot go on `managed_policy` — #15 established it is a genuine user-scope switch — and `hook` is element-level, so a file-wide switch has no home there. `allowedHttpHookUrls` and `httpHookAllowedEnvVars` are the same shape: hook-wide, any-scope, no managed gate. `allowManagedHooksOnly` stays on `managed_policy` and the two cross-reference. |

### One new element-level resource — 1

**`ssh_config`** for `sshConfigs`:
`dt(Se({id,name,sshHost,sshPort,sshIdentityFile,startDirectory}))`. It is an
**array of records with an explicit identity field** —
`id: "Unique identifier for this SSH config. Used to match configs across settings sources."`
The binary states the merge semantics outright, which is precisely #9's
criterion for element-level rather than a whole-array param.

## The phantom entries

### 15 named keys

Verified by counting **raw substring** occurrences across the whole binary, not
just quoted forms, so a key cannot hide behind a different quoting style.

| Phantom key | On resource | Occurrences | What it really is |
|---|---|---:|---|
| `subagentModel` | `subagents` | 0 | does not exist |
| `subagentToolRestrictions` | `subagents` | 0 | does not exist |
| `subagentPermissionMode` | `subagents` | 0 | does not exist |
| `maxConcurrentSubagents` | `subagents` | 0 | does not exist |
| `maxSubagentSpawnDepth` | `subagents` | 0 | does not exist |
| `awaySummaryInterval` | `context` | 0 | does not exist. `awaySummaryEnabled` does, and hard-codes the interval (*"when you return after being away for 5+ minutes"*). |
| `dangerouslySkipPermissionMode` | `permissions` | 0 | does not exist. `skipDangerousModePermissionPrompt` does. |
| `disallowedMcpServers` | `mcp_settings` | 0 | does not exist. The real key is `deniedMcpServers`, which #9 already lists under `managed_policy` — the table carried one concept twice, once under a name that does not exist. |
| `pluginBlocklist` | `managed_policy` | 0 | does not exist. `blockedMarketplaces` and `strictKnownMarketplaces` are the real lockdown keys, both already in the table. |
| `disableBrowserExternalNavigation` | `managed_policy` | 0 | **documented, dead in the CLI** — below |
| `disableMobileSimulatorTools` | `managed_policy` | 0 | **documented, dead in the CLI** — below |
| `agents` | `subagents` | 1909 | none a settings key. `--agents <json>` is a CLI flag; `.claude/agents/` is a directory. The docs' only `agents` table row (`settings.md:1208`) is in the **`strictPluginOnlyCustomization` surfaces** table — the `zpt=["skills","agents","hooks","mcp"]` value list — not a settings-key table. #9's "Agents are files only" ruling is right for a reason it did not have: there is no `agents` settings key to rule against. |
| `permissionMode` | `permissions` | 310 | none a settings key. It is the `--permission-mode` flag / SDK option. The settings form is `permissions.defaultMode`. |
| `strictMcpConfig` | `mcp_settings` | 29 | all the `--strict-mcp-config` CLI flag. Never read from a settings file. |
| `remoteControlSessionNamePrefix` | `remote_control` | 2 | both the commander option, which sets `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX`. CLI-only. |

### Plus 3 uncounted slots — new in this audit

**#9's `managed_policy` row opens with "the 8 `allowManaged*Only` keys". There
are five, and only three are top-level settings keys.** Exhaustive
`grep -a -o 'allowManaged[A-Za-z]*' | sort -u` returns exactly:

- `allowManagedHooksOnly`, `allowManagedPermissionRulesOnly`,
  `allowManagedMcpServersOnly` — top-level, on `managed_policy`
- `allowManagedDomainsOnly` — **nested**, `sandbox.network.*`
- `allowManagedReadPathsOnly` — **nested**, `sandbox.filesystem.*`

A widened `grep -a -o 'allow[A-Za-z]*Only'` adds only `allowOnly`, which is not
a settings key. So `managed_policy`'s stated 17 is inflated by three phantom
slots on top of the five named phantoms it carries, and two of the five real
ones belong to `sandbox`, not to it.

## Documented but dead — 3

Three keys appear in the public settings table and have **zero occurrences in
2.1.199, 2.1.204, 2.1.223, 2.1.224 and 2.1.225**:

- `disableBrowserExternalNavigation` — docs: *"(Managed settings only) … turn off external browsing in the **desktop app's** Browser pane"*
- `disableMobileSimulatorTools` — docs: *"… the **desktop app's** iOS Simulator pane"*
- `browserExternalPageTools` — docs: *"… the **desktop app's** Browser pane"* (never in #9's table)

All three configure Claude Code **desktop**, not the CLI. A CLI-only package
should not type them. Recommendation: **leave them out and name them in the
README's known limits.** They are the exact case #9's generic `setting`
resource exists for — a key that is real somewhere but that this package cannot
verify.

## Documented on the settings page but not `settings.json` keys — 6

`settings.md:351` carries a *"Global config settings"* section stating: *"These
settings are stored in `~/.claude.json` rather than `settings.json`. If you add
these keys to `settings.json`, Claude Code silently ignores them at startup."*
Its six keys are `autoConnectIde`, `autoInstallIdeExtension`, `diffTool`,
`externalEditorContext`, `permissionExplainerEnabled`, `teammateDefaultModel`.

The authoritative binary counterpart is **`GLOBAL_CONFIG_KEYS` → `qui`** (byte
**281 839 314**, 48 entries), exported alongside `PROJECT_CONFIG_KEYS → Egf`
(3 entries: `allowedTools`, `hasTrustDialogAccepted`,
`hasCompletedProjectOnboarding`) and `DEFAULT_GLOBAL_CONFIG → qce`. The gate
`BES(e){return qui.includes(e)}` is what `claude config -g` tests against.

Five of the documented six are in `qui`. **`teammateDefaultModel` is not** — yet
it *is* a `~/.claude.json` key, written by the `/config` UI through the global
config writer `Br()` (`Br((Q)=>Q.teammateDefaultModel===W?Q:{...Q,teammateDefaultModel:W})`,
byte **276 640 815**). So it is reachable by `state_setting` but invisible to
`claude config`, which is a distinction the docs do not draw.

Two consequences:

1. **These six are `state_setting`'s, not a section resource's.** #9's split of
   `setting` and `state_setting` is vindicated: the docs put both files' keys on
   one page, and an author copying from that page into `settings.json` gets
   silent no-ops.
2. **Nineteen names appear in *both* registries** — `agentPushNotifEnabled`,
   `apiKeyHelper`, `autoCompactEnabled`, `autoScrollEnabled`,
   `autoUploadSessions`, `editorMode`, `env`, `fileCheckpointingEnabled`,
   `inputNeededNotifEnabled`, `preferredNotifChannel`, `remoteControlAtStartup`,
   `respectGitignore`, `showMessageTimestamps`, `showTurnDuration`,
   `terminalProgressBarEnabled`, `theme`, `todoFeatureEnabled`, `verbose`,
   `workflowSizeGuideline`. A `ui.theme` and a `state_setting` for `theme` can
   both converge green while disagreeing. This is a new README known limit and a
   doc-cell warning on every affected section resource.

## The dangerous-settings consent hash — new in this audit

`cIc` (byte **268 661 599**) is a list of the **ten settings keys that carry a
shell command**:

`apiKeyHelper`, `awsAuthRefresh`, `awsCredentialExport`, `fileSuggestion`,
`gcpAuthRefresh`, `otelHeadersHelper`, `processWrapper`, `proxyAuthHelper`,
`statusLine`, `subagentStatusLine`

`D5e(e)` (byte **276 760 788**) walks `cIc` — accepting either a bare string or
an object with a `.command` string — and returns
`{shellSettings, envVars, hasHooks, hooks, hasClaudeMd, claudeMd}`. `Rna` JSON-
serialises that payload and `Dna` SHA-256s it into a `dangerousSettingsHash`,
which `sip`/`lip` compare against a `consented_payload` or an `org_record`.

**This is a real constraint on the package.** Converging *any* of those ten
keys, or `env`, or `hooks`, or `claudeMd`, changes the hash and **invalidates
the user's prior consent**, so the next interactive start re-prompts. That
touches `auth`, the new `status_line`, `ui.fileSuggestion`, `env_var`, `hook`
and `managed_policy.claudeMd` — six resources. It belongs in the README's known
limits and in each of those resources' doc cells.

It also corrects #13, which said *"All four — `apiKeyHelper`, `proxyAuthHelper`,
`awsAuthRefresh`, `gcpAuthRefresh` — follow #10's rule"*. There are **ten**
command-valued keys, and #10's "the resource manages the setting, never the
script" rule has to reach all of them.

## The sandbox surface, which the table under-counts by an order of magnitude

`sandbox` is one key in the schema (`sandbox:NQr().optional()`) and #9's table
names four leaves. `NQr` at byte **268 492 446** has **15 members**:

`enabled`, `failIfUnavailable`, `autoAllowBashIfSandboxed`,
`allowUnsandboxedCommands`, `network`, `filesystem`, `credentials`,
`ignoreViolations`, `enableWeakerNestedSandbox`, `enableWeakerNetworkIsolation`,
`allowAppleEvents`, `excludedCommands`, `ripgrep`, `bwrapPath`, `socatPath`

- `network` (`G1g`, byte **268 474 198**) — **11** leaves: `allowedDomains`, `deniedDomains`, `strictAllowlist`, `allowManagedDomainsOnly`, `allowUnixSockets`, `allowAllUnixSockets`, `allowLocalBinding`, `allowMachLookup`, `httpProxyPort`, `socksProxyPort`, `tlsTerminate.{caCertPath,caKeyPath}`
- `filesystem` (`W1g`, byte **268 476 834**) — **6** leaves: `allowWrite`, `denyWrite`, `denyRead`, `allowRead`, `allowManagedReadPathsOnly`, `disabled`
- `credentials` (`K1g`, byte **268 489 542**) — **5** leaves: `files[]`, `envVars[]`, `allowPlaintextInject`, `awsPairs[]`, `sigv4`

**≈40 typed params on one resource** — larger than any resource in this library.
Recommend splitting into `sandbox`, `sandbox_network`, `sandbox_filesystem` and
`sandbox_credentials`, which would take the inventory to **41 resources**.
Flagged rather than decided: this is a design ticket's call, and the `sandbox.*`
scope rules are unusually intricate.

## Nested objects: the table counts keys, the resources need leaves

Seventeen of the 155 keys are fixed-schema nested objects, so "one param per
key" understates the implementation. Verified leaf counts: `permissions` 7,
`sandbox` ~40, `hooks` (per #15), `attribution` 3, `worktree` 4, `statusLine` 5,
`subagentStatusLine` 2, `voice` 3, `breakReminder` 4, `quietHours` 3,
`fileSuggestion` 2, `spinnerVerbs` 2, `spinnerTipsOverride` 2, `remote` 1,
`xaaIdp` 3, `policyHelper` 3, `sshConfigs` 6 per element, `autoMode` 5,
`pluginConfigs` map-of-`{mcpServers,options}`. Expanding them puts the package's
typed-param count near **230**, not 155.

## Corrections to earlier tickets

**#13's `autoUpdatesChannel` values are wrong.** #13 states the legal values are
`disabled` / `rc` / `slow` / `latest`. The schema reads `["latest","stable","rc"]`
in **all three** of 2.1.223 (`w.enum([…])`), 2.1.224 (`Ir([…])`) and 2.1.225
(`$r([…])`) — only the minifier alias differs. The list #13 found is the
`/config` **option list**, where `slow` is a display alias for `rc`
(`autoUpdatesChannel==="rc"?"slow":…`) and `disabled` is what the row shows when
auto-updates are off via `~/.claude.json`. Confirmed from the other direction by
the install path:
`if(r==="latest"||r==="stable"||r==="rc"){let h=r==="rc"?"stable":r;await ts("userSettings",{autoUpdatesChannel:h})}`
— `claude install rc` writes `"stable"`.

So `auto_update.channel` must declare **`:latest`, `:stable`, `:rc`** — and
`:disabled` is not a channel value, which restores #13's own larger point
(disabling lives in `~/.claude.json`'s `autoUpdates`) on firmer ground than the
value list it used to make it.

**#13's `forceLoginMethod` values are confirmed**: `$r(["claudeai","console","gateway"])`.

**#12 and #15's handoffs are all placed:** `enabledMcpjsonServers` /
`disabledMcpjsonServers` on `mcp_server` (unchanged), `skillOverrides` on the new
`skills`, `enforceAvailableModels` on `model`, `includeGitInstructions` on
`attribution`, `disableAllHooks` on the new `hook_policy`,
`strictPluginOnlyCustomization` on `managed_policy`.

**#15's 31 hook events are confirmed**, incidentally: `Dz` is a 31-element array
and `HUg=new Set(Dz)` is its membership gate. The five settings sources are
`R$=["userSettings","projectSettings","localSettings","flagSettings","policySettings"]`.

## Where this audit overturns the earlier draft

The draft's three headline numbers (155 / 56 / 99) and its sandbox offsets and
leaf counts all reproduced exactly. These did not:

1. **The `allowManaged*Only` over-count is new.** The draft did not notice that
   #9's "8 `allowManaged*Only` keys" names five real keys, of which two are
   `sandbox`'s. Three of `managed_policy`'s 17 slots are phantom.
2. **The `cIc` / dangerous-settings-consent finding is new**, and it is the one
   with the widest blast radius across the design.
3. **The global-config key list was wrong.** The draft read a heap string run by
   byte range and produced a list missing `showTurnDuration`, `respectGitignore`,
   `copyFullResponse`, `autoAddRemoteControlDaemonWorker` and `remoteDialogSeen`.
   The authoritative source is the exported `GLOBAL_CONFIG_KEYS` (`qui`), 48
   entries.
4. **The dual-registry count was wrong** — the draft says "Fifteen names" and
   then lists seventeen. Computed against `qui`, it is **19**.
5. **`teammateDefaultModel` is not in `GLOBAL_CONFIG_KEYS`.** The draft asserted
   all six documented global keys are in that registry; five are.
6. **The `agents` docs row is mis-cited.** The draft calls `settings.md:1208` a
   *directory* table; it is the `strictPluginOnlyCustomization` surfaces table.
   The conclusion (not a settings key) is unaffected.
7. **`ultracode` is session-scoped**, which the draft did not report:
   *"Session-scoped — typically provided via `--settings` or the
   `apply_flag_settings` control request; interactive toggles never persist it."*
   Typing it as an ordinary persisted param on `workflows` writes a key the
   binary does not expect to find in a settings file. Flagged as uncertain.
8. **`permissions` has 7 leaves**, not the draft's "6+"; `autoMode` has 5, not
   #9's 4 (`classifyAllShell` is missing from the table).
9. **The draft cited byte 100 978 232 for the `enforceAvailableModels` warning
   string.** That message lives in `cns`, in the schema region near byte
   268 777 090; the 100.9 M region is the V8 heap string table, which holds
   copies. Offsets into the heap table are not stable citations for code, and
   this audit cites the code region instead.
10. **The draft's arithmetic sentence "148 named keys + 7 from `VIc` = 155"** is
    off by one in both directions: it is 147 named (excluding `$schema`) + 1
    `xaaIdp` + 7. The total is right and its table is right; only the derivation
    was mis-stated.
11. **`autoUpdatesChannel` in 2.1.224** does not literally read `$r([…])` as the
    draft claimed — it reads `Ir([…])`. The values are identical, and this audit
    additionally checked 2.1.223.

Nothing in the draft was deleted as unreproducible; items 1–3 are additions and
4–11 are corrections.

## Uncertain — flagged rather than guessed

- **`claudeMdExcludes` → `context`.** No managed gate (unlike `claudeMd`, which is *"Only honored from managed/policy settings"*), so it cannot join `claudeMd` on `managed_policy`. `context` fits by subject, but the `claude_md` content resource has a claim. Two keys with near-identical names on different resources is a docs hazard either way.
- **`ultracode` → `workflows`.** Its own description says settings persistence is not its intended route. It may belong nowhere in this package.
- **`disableAgentView` → `subagents`.** It disables background agents and the daemon, which is nearer `remote_control`.
- **`plansDirectory` → `context`.** Could equally be `ui` or a session-artifacts resource.
- **`defaultShell` / `respondToBashCommands` → `ui`.** Both are about the input-box `!` command, which is UI — but `defaultShell` (`bash`/`powershell`) changes how a command executes, which is not.
- **`fileCheckpointingEnabled` → `features`.** It is `/rewind`'s file snapshotting; `context` has a claim.
- **`doneMeansMerged` → `features`.** `@internal`, and its description is about agent-loop termination, which is nearer `workflows`.
- **`dialogExpiry` → `remote_control`, `askUserQuestionTimeout` → `ui`.** Identical types (`$r(["60s","5m","10m","never"])`) split across two resources on the strength of their descriptions. Defensible, not obvious.
- **`notifications` as a separate resource.** Three keys. The weakest of the seven proposals; folding into `ui` is reasonable.
- **`allowAllClaudeAiMcps` → `mcp_settings` vs `managed_policy`.** It carries a managed gate, so `managed_policy` is arguably correct; kept on `mcp_settings` for readability.
- **`skipWebFetchPreflight` → `features`.** Its description says *"for enterprise environments with restrictive security policies"* but states **no** managed-only gate, so `managed_policy`'s fixed `:enterprise` scope would be wrong. Worth re-reading at implementation time.
- **`ui` at 33 params after the split.** Too big, and no seam in the binary's ordering suggests where to cut it.

## What this does to the inventory

| | #9 (as amended) | This audit |
|---|---|---|
| Section resources | 13 | **20** (+`status_line`, `skills`, `workflows`, `worktree`, `notifications`, `features`, `hook_policy`) |
| Element-level | 5 | **6** (+`ssh_config`) |
| Install | 2 (per #13: `installed`, `auth_provider`) | unchanged |
| Content | 5 | unchanged |
| Plugins and MCP | 3 | unchanged |
| Generic | 2 | unchanged |
| **Total resources** | **30** | **38** |
| Gatherers | 2 | 2 |

If the `sandbox` split is also taken, **41**.

#9's concurrency assignment extends mechanically: every new section resource and
`ssh_config` read-modify-write the same `settings.json`, so all eight are
`global`. The tally moves from #13's 25/4/1 to **33 `global`, 4 `parallel`,
1 `exclusive`**.

## Verdict on #9's headline claim

#9 claims *"every documented key gets typed coverage"*, with `setting` reserved
for keys that ship after we do. As written the claim is untrue: **99 of the
binary's 155 keys are untyped and undocumented**, and 15 named entries in the
table — plus 3 uncounted `allowManaged*Only` slots — are for keys that are not
settings keys at all.

Both halves matter, and the second is worse: a typed param for `subagentModel`
would validate, converge green, write a key nothing reads, and never report
drift. The loader's `.passthrough()` guarantees it never complains.

The claim is recoverable, and cheaply. The surface is finite, the schema is one
contiguous literal, and **every key in it carries its own `.describe()` string,
which is the doc cell already written**. What it costs is seven more section
resources and the honesty of saying so.
