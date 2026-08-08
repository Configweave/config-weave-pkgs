# `~/.claude/keybindings.json` — schema and scope

Research for issue #16 (design input for a `claude_code` `keybinding` resource).

Every claim below was re-derived from scratch for this pass. Where it overturns
the earlier unreviewed draft, the correction is marked **[CORRECTED]**.

Sources:

- **BIN** — `/home/wil/.local/share/claude/versions/2.1.225` (Claude Code
  2.1.225, ELF-wrapped bundled JS). Older installed builds 2.1.199, 2.1.204,
  2.1.223, 2.1.224 used for version comparison. Greps quoted verbatim.
- **RUN** — end-to-end runs of the real CLI in throwaway `HOME`s under
  `$SCRATCH`. Scripts kept at `$SCRATCH/{probe,kbcmd3,hotreload,nooverwrite,projectlevel,configdir}.sh`.
  The real `/home/wil/.claude/` was read-only throughout and contains **no**
  `keybindings.json` (`ls -la /home/wil/.claude/`).
- **SKILL** — the "Keybindings Skill" markdown embedded in the binary
  (`grep -a 'ZHE=\["# Keybindings Skill"'`). First-party, ships with the CLI.
- **DOC** — <https://code.claude.com/docs/en/keybindings>
- **STORE** — <https://www.schemastore.org/claude-code-keybindings.json>

---

## 0. Contradictions with the ticket premise

1. **The file is not a chord→command map.** The recorded settings-research line
   ("JSON format: key binding → command/action mapping") describes only the
   *inner* object. The top level is `{$schema?, $docs?, bindings: [...]}` where
   `bindings` is an **array of per-context blocks**. Identity is
   `(context, chord)`, not `chord`.

   A flat map is not merely a different spelling — it is rejected outright.
   RUN, `$SCRATCH/probes/t_flatmap.json` = `{"ctrl+e":"chat:stash"}`:

   ```
   [keybindings] KeybindingSetup initialized with 179 bindings, 0 warnings
   ```

   179 is the default count. The file was discarded whole.

2. **`allowManagedKeybindingsOnly` does not exist.** Zero hits in all five
   installed builds:

   ```
   $ for v in ~/.local/share/claude/versions/*; do grep -a -c 'allowManagedKeybindingsOnly' $v; done
   2.1.199: 0   2.1.204: 0   2.1.223: 0   2.1.224: 0   2.1.225: 0
   ```

   The real family is exactly five keys, none about keybindings:

   ```
   $ grep -a -o -P 'allowManaged[A-Za-z]*Only' 2.1.225 | sort -u
   allowManagedDomainsOnly  allowManagedHooksOnly  allowManagedMcpServersOnly
   allowManagedPermissionRulesOnly  allowManagedReadPathsOnly
   ```

   There is **no keybindings key in `settings.json` at all** — the only
   `"keybindings"` string literals in the binary are the safe-mode gate
   `Rp("keybindings")` and the warm-backend state id (§2.3).

3. **`~/.claude/keybindings.json` is the only file.** Exactly one path join in
   the binary:

   ```
   $ grep -a -o -P 'function Ypn\(\)\{.{0,60}' 2.1.225
   function Ypn(){return gLo.join(Ln(),"keybindings.json")}
   ```

   `Ln()` is the Claude config dir — the same helper as
   `join(Ln(),"settings.json")`, `join(Ln(),"skills")`, `join(Ln(),"projects")`,
   `join(Ln(),"history.jsonl")`, all of which exist under `~/.claude`.

   Confirmed by RUN, three ways:
   - **No project scope.** `$SCRATCH/projectlevel.sh` put a 5-binding file at
     both `<cwd>/.claude/keybindings.json` and `<cwd>/keybindings.json` with no
     user-level file. Result: `initialized with 179 bindings`, and the watcher
     line named only the `$HOME/.claude` path. Both project files ignored.
   - **No managed/enterprise scope.** `managed-settings.json` appears 30 times
     in the binary; no keybindings path is ever joined against it.
   - **`CLAUDE_CONFIG_DIR` relocates it.** `$SCRATCH/configdir.sh`:
     `Loaded 2 user bindings from …/altcfg/keybindings.json`.

4. **Plugins cannot ship keybindings.** The plugin component schema is
   `commands, agents, skills, hooks, mcpServers, lspServers` —
   `grep -a -o -P 'commands:dt\(e3a\(\)\),agents:.{0,120}'`. No keybindings
   member.

5. **`/keybindings` seeds the file with a full copy of the defaults.** Not an
   empty overlay — see §7. Any `check()` that reads "entry present ⇒ user
   intent" is wrong on such a machine.

6. **DOC's uppercase rule is false in 2.1.225.** DOC: "A standalone uppercase
   letter implies Shift. For example, `K` is equivalent to `shift+k`." The
   binary does not implement this — §3.3. **[CORRECTED]** the draft left this
   as an unresolved code reading; it is now settled by an observed collision.

---

## 1. Top-level shape

BIN, the zod schema that generates the published JSON Schema:

```js
TxT=Ee(()=>Se({
  $schema:$().optional().describe("JSON Schema URL for editor validation"),
  $docs:$().optional().describe("Documentation URL"),
  bindings:dt(Xf_()).describe("Array of keybinding blocks by context")
}).describe("Claude Code keybindings configuration. Customize keyboard shortcuts by context."))
```

```js
Xf_=Ee(()=>Se({
  context:$r(mSr).describe("UI context where these bindings apply. Global bindings work everywhere."),
  bindings:Wn($().describe('Keystroke pattern (e.g., "ctrl+k", "shift+tab")'),
    fs([$r(x1s),
        $().regex(/^command:[a-zA-Z0-9:\-_]+$/).describe('Command binding (e.g., "command:help", "command:compact"). Executes the slash command as if typed.'),
        rge().describe("Set to null to unbind a default shortcut")])
   .describe("Action to trigger, command to invoke, or null to unbind"))
   .describe("Map of keystroke patterns to actions")
}).describe("A block of keybindings for a specific context"))
```

So:

```json
{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings",
  "bindings": [
    { "context": "Chat", "bindings": { "ctrl+e": "chat:externalEditor", "ctrl+u": null } }
  ]
}
```

The **runtime loader does not use `TxT`.** It uses a much looser guard plus
hand-written validators:

```js
Jf_=Ee(()=>Se({context:$(),bindings:Wn($(),$().nullable())}))
function Qf_(e){return Jf_().safeParse(e).success}
function Kpn(e){return Array.isArray(e)&&e.every(Qf_)}
```

Consequences in §6. `Se` is `z.object`, which strips unknown keys — an extra
property on a block is silently tolerated (RUN: a block with `"extraKey": 1`
produced no diagnostic).

`$schema`/`$docs` are optional, but SKILL says "Always include the `$schema` and
`$docs` fields" and `/keybindings` writes both.

**The file must be strict JSON.** A trailing comma kills it — RUN,
`$SCRATCH/probes/t_badjson.json`:

```
[keybindings] Error loading …/keybindings.json: JSON Parse error: Property name must be a string literal
[keybindings] KeybindingSetup initialized with 179 bindings, 1 warnings
```

SKILL agrees: "JSON config files (`settings.json`, `.mcp.json`,
`keybindings.json`) never contain \`…". No JSONC, no comments.

**Multiple blocks may share a `context`, and they merge.** `qpn` flattens every
block into one flat list keyed by nothing:

```js
function qpn(e){let t=[];for(let r of e)for(let[n,o]of Object.entries(r.bindings))
  t.push({chord:YW(n),action:o,context:r.context});return t}
```

RUN confirmed: a probe with two separate `{"context":"Chat"}` blocks (12 + 1
entries) plus three other blocks loaded all 19 — no block replaced another.

---

## 2. Loading, merge and precedence

### 2.1 Merge

BIN, `um_` (and the identical inline path in `qud`):

```js
let a=qpn(s);
w(`[keybindings] Loaded ${a.length} user bindings from ${n}`);
let l=[...r,...a];        // r = defaults, a = user
```

and the dispatcher `j_t`:

```js
let u; for(let d of a) if(bLo(i,d.chord)) u=d;
if(u){ if(u.action===null) return{type:"unbound"}; return{type:"match",action:u.action} }
```

Defaults first, user appended; the loop keeps the **last** match, so a user
entry beats a default for the same `(context, chord)`. Merge is per-entry, not
per-context: a user block for `Chat` does not drop the other `Chat` defaults.

RUN, arithmetic on three separate runs: 179 + 0 = 179; 179 + 19 = 198;
179 + 173 = 352.

### 2.2 Hot reload

Observed, not just inferred. `$SCRATCH/hotreload.sh` mutated the file mid-session:

```
[keybindings] Loaded 1 user bindings from …/keybindings.json
[keybindings] KeybindingSetup initialized with 180 bindings, 0 warnings
[keybindings] Watching for changes to …/keybindings.json
[keybindings] Detected change to …/keybindings.json
[keybindings] Loaded 3 user bindings from …/keybindings.json
[keybindings] Reloaded: 182 bindings, 0 warnings
[keybindings] Detected deletion of …/keybindings.json
[keybindings] Reloaded: 179 bindings, 0 warnings
```

Deleting the file restores defaults with no restart. The watcher is armed even
when the file does not exist (baseline run with no file still logged
`Watching for changes to …`).

### 2.3 Non-filesystem source

`cm_=Cc.state("keybindings")`. In `qud`, a warm backend **replaces** the disk
read rather than layering on it:

```js
if(t){let i=await t.read([cm_]); … return um_(Buffer.from(s.value).toString("utf-8"),…)}
try{let i=await hLo.readFile(o,"utf-8"); …}
```

So in a remote/web Claude Code session the local file is not consulted at all.
*Descriptor read from BIN; the transport was not exercised.* **UNCONFIRMED**
whether a config manager can ever reach this store.

### 2.4 Kill switches

- Feature gate `s_e(){return nt("tengu_keybinding_customization_release",!0)}` —
  default on.
- **Safe mode disables user keybindings entirely.** `Wud(){return !s_e()||Rp("keybindings")}`,
  and the safe-mode allowlist has `keybindings:!1`:
  `XYy={claudeMd:!1,…,keybindings:!1}`, `Rp(e,t){if(Jc()&&!XYy[e])return!0;…}`,
  `Jc(){return _r(process.env.CLAUDE_CODE_SAFE_MODE)||s8i("--safe-mode")}`.
  The `/keybindings` handler says so: `"(Safe mode: custom keybindings are
  disabled this session — changes take effect after you ${px()}.)"`.

---

## 3. Chord grammar

### 3.1 Two functions, two jobs

`fSr` parses a **binding string** into the record used for matching:

```js
function fSr(e){let t=e.split("+"),r={key:"",ctrl:!1,alt:!1,shift:!1,meta:!1,super:!1};
 for(let n of t){let o=n.toLowerCase();switch(o){
  case"ctrl":case"control":r.ctrl=!0;break;
  case"alt":case"opt":case"option":r.alt=!0;break;
  case"shift":r.shift=!0;break;
  case"meta":r.meta=!0;break;
  case"cmd":case"command":case"super":case"win":r.super=!0;break;
  case"esc":r.key="escape";break; case"return":r.key="enter";break;
  case"del":r.key="delete";break; case"space":r.key=" ";break;
  case"↑":r.key="up";break; case"↓":r.key="down";break;
  case"←":r.key="left";break; case"→":r.key="right";break;
  default:r.key=o;break}}return r}
function YW(e){if(e===" ")return[fSr("space")];return e.trim().split(/\s+/).map(fSr)}
```

`Kf_`/`i4t` produce a **canonical string** used for duplicate and reserved
detection:

```js
function Kf_(e){let t=e.split("+"),r=[],n="";
 for(let o of t){let i=o.trim().toLowerCase();
  if(["ctrl","control","alt","opt","option","meta","cmd","command","super","win","shift"].includes(i))
   if(i==="control")r.push("ctrl");
   else if(i==="option"||i==="opt"||i==="meta")r.push("alt");
   else if(i==="command"||i==="cmd"||i==="super"||i==="win")r.push("cmd");
   else r.push(i);
  else n=Vf_[i]??i}
 return r.sort(),[...r,n].join("+")}
function i4t(e){if(e===" ")return"space";return e.trim().split(/\s+/).map(Kf_).join(" ")}
Vf_={esc:"escape",return:"enter",del:"delete","↑":"up","↓":"down","←":"left","→":"right",
     caps:"capslock","caps-lock":"capslock",caps_lock:"capslock"}
```

Every token is lowercased; modifiers are sorted alphabetically; aliases collapse.

### 3.2 Normalisation — observed

RUN, `$SCRATCH/h1` (`claude --debug` in a throwaway `HOME`, debug log excerpt):

```
[keybindings] [warning] Duplicate binding "ctrl+s" in Chat context — Previously bound to "null".
[keybindings] [warning] Duplicate binding "shift+ctrl+p" in Chat context — Previously bound to "chat:modelPicker".
[keybindings] [warning] Duplicate binding "k" in Chat context — Previously bound to "chat:submit".
[keybindings] [warning] Duplicate binding "ctrl+meta+a" in Chat context — Previously bound to "chat:submit".
```

from input keys `Ctrl+S`/`ctrl+s`, `ctrl+shift+P`/`shift+ctrl+p`, `K`/`k`,
`ctrl+alt+a`/`ctrl+meta+a`. So, empirically:

- **case-insensitive** (`Ctrl+S` ≡ `ctrl+s`)
- **modifier-order-insensitive** (`ctrl+shift+P` ≡ `shift+ctrl+p`)
- **`meta` ≡ `alt`** (`ctrl+meta+a` ≡ `ctrl+alt+a`)
- **bare `K` ≡ bare `k`** — see §3.3

A resource that writes `Ctrl+S` and then looks for `ctrl+s` will not see its own
entry. It must canonicalise with the same rules before comparing.

### 3.3 Uppercase does NOT imply Shift **[CORRECTED — draft left this open]**

DOC says `K` ≡ `shift+k`. Three independent lines of evidence say otherwise in
2.1.225:

1. **Observed.** `"K"` and `"k"` in the same `Chat` block collide as duplicates
   (§3.2). If `K` meant `shift+k` they would be different bindings.
2. **Binding side.** `fSr` lowercases the base key (`default:r.key=o` where
   `o=n.toLowerCase()`) and never sets `shift`. `"K"` → `{key:"k",shift:false}`.
3. **Keypress side.** `edd` lowercases the physical key and *infers* shift from
   the character's case:

   ```js
   let n=pm_[e.name]??(t.length===1?t.toLowerCase():null);
   let o=e.shift||t.length===1&&t!==t.toLowerCase()&&t===t.toUpperCase();
   return{key:n,ctrl:e.ctrl,alt:r,shift:o,meta:r,super:e.superKey}
   ```

   Pressing Shift+K yields `{key:"k",shift:true}`, and `hSr` requires
   `e.shift===t.shift`.

Therefore a binding written `"K"` matches an **unshifted `k`**. DOC's companion
claim — `ctrl+K` ≡ `ctrl+k` — *is* true. The shipped defaults agree with the
code, not the docs: they write `"shift+k":"messageSelector:top"` and
`"shift+g":"scroll:bottom"`, never `"K"`/`"G"`.

Not verified by an actual keypress (no interactive terminal available), but the
binding side, the keypress side and the normaliser all agree.

**Practical rule for the resource: always emit `shift+k`, never `K`.**

### 3.4 Grammar summary

- Keystroke = `mod+mod+key`, `+`-separated, any order, any case.
- Modifier aliases (from `fSr`): `ctrl`|`control`; `alt`|`opt`|`option`;
  `shift`; `meta`; `cmd`|`command`|`super`|`win`.
- `alt` and `meta` are the same bit end-to-end. `hSr` compares
  `(e.alt||e.meta)===(t.alt||t.meta)`, and `edd` assigns both from one variable
  (`alt:r, meta:r`). **SKILL is wrong here** — it says "`meta` (aliases: `cmd`,
  `command`)" in one bullet while saying "`alt` and `meta` are identical in
  terminals" in the bullet above. The code says `meta`≡`alt`; `cmd` is the
  separate Super group. DOC gets this right.
- The `cmd`/`super`/`win` group is separate and, per DOC, only delivered by
  terminals reporting Super (Kitty protocol / xterm `modifyOtherKeys`).
- Named keys the runtime can actually produce (`pm_`):
  `escape, enter, tab, backspace, delete, up, down, left, right, pageup,
  pagedown, wheelup, wheeldown, home, end`. `wheelup`/`wheeldown` are
  undocumented. Anything else must be a single character.
- `capslock` is in the alias map and the reserved list but **not** in `pm_` — it
  is unreachable by design.
- **Chords** = whitespace-separated keystrokes (`ctrl+k ctrl+s`); canonical form
  joins with a single space, so runs of whitespace collapse. SKILL: 1-second
  inter-keystroke timeout.
- Any literal character is a legal key — the defaults include `/`, `ctrl+]`,
  `ctrl+-`, `ctrl+_`.
- **There is no key-name validation whatsoever.** RUN: `"f5"` and `"wheelup"`
  loaded with zero diagnostics. A typo'd key name is silently inert.

---

## 4. Unbinding

Expressible in the file, and distinct from absence:

- `"ctrl+s": null` → `j_t` returns `{type:"unbound"}`, terminating the lookup;
  the default does not fire.
- **Removing** the entry restores the default (defaults are always the base
  layer). Observed at file granularity in §2.2: deleting the whole file dropped
  182 → 179.
- SKILL, verbatim: "User bindings are **additive** — they are appended after the
  default bindings"; "To **move** a binding to a different key: unbind the old
  key (`null`) AND add the new binding".
- Chord-prefix reservation. `j_t` collects every longer chord that prefix-matches
  and enters `chord_started` if **any** of them has a non-null action:

  ```js
  for(let d of a)if(d.chord.length>i.length&&tdd(i,d))l.set(x0e(d.chord),d.action);
  let c=!1;for(let d of l.values())if(d!==null){c=!0;break}
  if(c)return{type:"chord_started",pending:i};
  ```

  So reclaiming `ctrl+x` as a single key means nulling `ctrl+x ctrl+k` and
  `ctrl+x ctrl+e` (Chat) **and** `ctrl+x ctrl+b` (Task). DOC documents exactly
  this and matches the code.

**Design consequence.** A resource has three states per `(context, chord)`:
bound to an action, explicitly `null`, or absent. `ensure = :absent` must choose
between *delete the entry* (restore the default) and *write `null`* (suppress
the default). They are different outcomes and both are legitimate intents.

---

## 5. The action side

A JSON **string** or **null**. Never an object; no arguments. Two string forms:

1. **A built-in action id**, `namespace:action`. The enum `x1s` has **136**
   entries across 24 namespaces in 2.1.225:

   | ns | n | ns | n | ns | n |
   |---|---|---|---|---|---|
   | `chat` | 17 | `app` | 14 | `strip` | 13 |
   | `scroll` | 10 | `confirm` | 9 | `selection` | 8 |
   | `select` | 8 | `footer` | 8 | `diff` | 7 |
   | `settings` | 5 | `messageSelector` | 5 | `historySearch` | 5 |
   | `autocomplete` | 4 | `attachments` | 4 | `plugin` | 3 |
   | `modelPicker` | 3 | `history` | 3 | `transcript` | 2 |
   | `theme` | 2 | `tabs` | 2 | `voice` | 1 |
   | `task` | 1 | `permission` | 1 | `help` | 1 |

   Re-extract with:
   `grep -a -o -P '\["app:interrupt".{0,4000}?\]' <binary> | head -1 | grep -o -P '"[^"]+"'`

2. **A slash-command binding**, `command:<name>`, matching
   `/^command:[a-zA-Z0-9:\-_]+$/` — "Executes the slash command as if typed."
   Open-ended by construction: any installed command, including plugin commands
   (`:` is legal). RUN: `"command:my-plugin:some-cmd"` loaded with zero
   diagnostics. Only meaningful in `Chat` — anywhere else is a **warning**, not
   an error:
   `[keybindings] [warning] Command binding "command:help" must be in "Chat" context, not "Select"`.

**The enum is not enforced at load time.** `tm_` checks only string-or-null, the
`command:` regex, the `command:`-context rule, and a `voice:pushToTalk`
ergonomics rule. RUN: `"chat:bogusAction"` produced **no diagnostic at all**. At
use time `m1()` falls back and fires telemetry:

```js
O("tengu_keybinding_fallback_used",{action:e,context:ge(t),fallback:r,reason:Ce("action_not_found")})
```

### 5.1 The enum churns between patch releases

Measured across the five installed builds:

```
$ for v in ~/.local/share/claude/versions/*; do
    grep -a -o -P '\["app:interrupt".{0,4000}?\]' $v | head -1 | grep -o -P '"[^"]+"' | wc -l; done
2.1.199: 119   2.1.204: 121   2.1.223: 134   2.1.224: 136   2.1.225: 136
```

Contexts move too: `Doctor` present in 2.1.199/2.1.204, gone by 2.1.223 (DOC:
removed in v2.1.205); `DiffPanel` absent in 2.1.199, present from 2.1.204 on.

**Design read: `action` must be an open string, not a symbol.** `command:*` is
unbounded, and the built-in enum gained 17 members across five builds spanning
about five weeks while losing one. A closed symbol set per this repo's
convention would break users on any CLI version other than the one the package
was authored against. The 136-value list is best used as a client-side *warning*
list, not a validation gate. Same argument applies to `context`, more weakly —
that enum is small and stable-ish, but `Doctor` still disappeared mid-series.

### 5.2 The published enums are incomplete **[CORRECTED — draft conflated DOC and STORE]**

- **Contexts.** Runtime has **20**; DOC and STORE both list **19**, omitting
  `DiffPanel`. The CLI's own error message prints all 20 (§6).
- **Actions.** STORE is a strict *subset* of the binary — it lists 116 distinct
  values, all of which exist in the binary. Missing exactly 20:

  ```
  app:cycleDiffBase app:toggleDiffNoiseFilter app:toggleDiffPreSession
  app:toggleReplTab app:toggleTerminal chat:attentionDown chat:attentionUp
  strip:jump1 … strip:jump9 strip:new strip:next strip:previous strip:toggle
  ```

  The draft claimed STORE also omits `theme:editCustom`, `footer:close`,
  `select:pageUp/pageDown/first/last` and `settings:periodDay/periodWeek/sortByTokens`.
  **That is wrong** — those are all in STORE. They are missing from the **DOC
  page's** tables, which are less complete still: on top of STORE's 20, the DOC
  tables also omit `app:toggleBrief`, `app:openArtifact`, `app:diffFileListUp`,
  `app:diffFileListDown`, `chat:workflowKeywordToggle`, `theme:editCustom`,
  `footer:close`, `select:pageUp`, `select:pageDown`, `select:first`,
  `select:last`, `settings:periodDay`, `settings:periodWeek`,
  `settings:sortByTokens`.

Completeness ordering: **binary (136) ⊃ SchemaStore (116) ⊃ docs page (~102)**.
Derive the enum from the binary or not at all.

---

## 6. Validation semantics — observed end-to-end

RUN, `$SCRATCH/h1`. Probe file (6 blocks, 19 entries):

```json
{"bindings":[
 {"context":"Chat","bindings":{
   "Ctrl+S":null,"ctrl+s":"chat:stash","ctrl+shift+P":"chat:modelPicker",
   "shift+ctrl+p":"chat:cancel","ctrl+q":"chat:bogusAction","ctrl+y":"command:compact",
   "K":"chat:submit","k":"chat:newline","ctrl+alt+a":"chat:submit",
   "ctrl+meta+a":"chat:newline","ctrl++b":"chat:submit","ctrl+z":"chat:cancel"}},
 {"context":"chat","bindings":{"ctrl+w":"app:help"}},
 {"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}},
 {"context":"Global","bindings":{"ctrl+k ctrl+t":"app:toggleTodos","ctrl+c":"app:exit"}},
 {"context":"Select","bindings":{"ctrl+u":"command:help"}},
 {"context":"Global","bindings":{"ctrl+\\":"app:exit","capslock":"app:exit"},"extraKey":1}]}
```

```
$ HOME=$SCRATCH/h1 script -qec "claude --debug" /dev/null
$ grep -a keybinding $SCRATCH/h1/.claude/debug/*.txt
[keybindings] Loaded 19 user bindings from …/keybindings.json
[keybindings] Found 11 validation issue(s)
[keybindings] [error] Empty key part in "ctrl++b" — Remove extra "+" characters
[keybindings] [error] Unknown context "chat" — Valid contexts: Global, Chat, Autocomplete,
  Confirmation, Help, Transcript, HistorySearch, Task, ThemePicker, Settings, Tabs,
  Attachments, Footer, MessageSelector, DiffDialog, DiffPanel, ModelPicker, Select, Plugin, Scroll
[keybindings] [warning] Command binding "command:help" must be in "Chat" context, not "Select"
[keybindings] [warning] Duplicate binding "ctrl+s" in Chat context — Previously bound to "null".
[keybindings] [warning] Duplicate binding "shift+ctrl+p" in Chat context — Previously bound to "chat:modelPicker".
[keybindings] [warning] Duplicate binding "k" in Chat context — Previously bound to "chat:submit".
[keybindings] [warning] Duplicate binding "ctrl+meta+a" in Chat context — Previously bound to "chat:submit".
[keybindings] [warning] "ctrl+z" may not work: Unix process suspend (SIGTSTP)
[keybindings] [error] "ctrl+c" may not work: Cannot be rebound - used for interrupt/exit (hardcoded)
[keybindings] [error] "ctrl+\" may not work: Terminal quit signal (SIGQUIT)
[keybindings] [error] "capslock" may not work: Caps Lock is not delivered to terminal applications
[keybindings] KeybindingSetup initialized with 198 bindings, 11 warnings
```

Reads directly off that:

- All 19 entries loaded (179 + 19 = 198). **The severity label "error" does not
  mean the entry was dropped** — the unknown-context and empty-key-part entries
  still counted. They are simply inert, because `j_t` filters by active context
  and `fSr` can never match a malformed key. **[CORRECTED]**
- The 20-context list is printed in full and includes `DiffPanel`.
- `chat:bogusAction` and `command:compact` in Chat: no diagnostic.
- `"extraKey": 1` on a block: no diagnostic.
- Nothing here fails startup, and nothing rewrites the file.

### 6.1 What actually discards the whole file

Errors that make the loader fall back to **defaults only**, throwing away every
user entry — all observed:

| Input | Result |
|---|---|
| malformed JSON (trailing comma) | `JSON Parse error…`, 179 bindings |
| no `bindings` key (`{"ctrl+e":…}`) | 179 bindings |
| `bindings` not an array (`{"bindings":{…}}`) | 179 bindings |
| **one action value that is not string-or-null** (`{"ctrl+f":123}`) | 179 bindings — the sibling valid `ctrl+e` entry was lost too |

The last one is the sharp edge. `Kpn`/`Jf_` gate the *whole document*, so a
single bad value nukes the file. **[CORRECTED]** — the draft listed this among
per-entry errors.

### 6.2 Per-entry diagnostics (non-fatal, debug log only)

| Condition | Severity | Function |
|---|---|---|
| unknown `context` | error | `tm_` |
| block missing `context` / `bindings` | error | `tm_` |
| empty key part (`"ctrl++s"`) | error | `em_` |
| reserved: `ctrl+c`, `ctrl+d`, `ctrl+m`, `capslock` | error | `om_`/`Vpn` |
| `ctrl+\` (SIGQUIT) | error | `om_`/`C1s` |
| `ctrl+z` (SIGTSTP) | warning | `om_`/`C1s` |
| macOS only: `cmd+c/v/x/q/w/tab/space` | error | `om_`/`k1s` |
| `command:` malformed, or outside `Chat` | warning | `tm_` |
| `voice:pushToTalk` on a bare letter | warning | `tm_` |
| duplicate canonical chord in one context | warning | `nm_` |
| duplicate raw JSON key in one `bindings` object | warning | `fLo` |

Two refinements on the duplicate rule:

- `nm_` only warns when the two actions **differ** (`if(l&&l!==s)`). Writing the
  same `(context, chord, action)` twice is silent — so a resource cannot rely on
  a duplicate warning to notice it has doubled up.
- `nm_`'s map is keyed on the **raw** `context` string, shared across blocks, so
  duplicates spanning two same-context blocks *are* detected.

All warnings and errors go to the debug log only (`--debug`). They never fail a
startup and never rewrite the file.

---

## 7. What `/keybindings` writes

`ocb={name:"keybindings",description:"Open your keyboard shortcuts file",
isEnabled:()=>s_e(),supportsNonInteractive:!1,type:"local"}` — REPL only.

```js
function Wlb(e){let t=new Set(Vpn.map((r)=>i4t(r.key)));
 return e.map((r)=>{let n={};for(let[o,i]of Object.entries(r.bindings))
  if(!t.has(i4t(o)))n[o]=i;return{context:r.context,bindings:n}})
  .filter((r)=>Object.keys(r.bindings).length>0)}
function cop(){let t={$schema:"https://www.schemastore.org/claude-code-keybindings.json",
 $docs:"https://code.claude.com/docs/en/keybindings",bindings:Wlb(pSr)};return De(t,null,2)+"\n"}
```

written with `flag:"wx"` — create-only — then `$EDITOR` is opened.

RUN, `$SCRATCH/kbcmd3.sh` (throwaway `HOME`, onboarding pre-seeded, `EDITOR=true`):

```
⎿  Created …/hk/.claude/keybindings.json with template. Opened in your editor.
$ wc -c …/hk/.claude/keybindings.json
7884
```

Measured contents: **19 blocks, 173 entries, 0 nulls, 107 distinct actions, no
`command:` entries, no uppercase chords.** **[CORRECTED]** — the draft said
"~187 entries"; it is 173. The arithmetic: 179 runtime defaults minus the 6
default entries whose chord is hardcoded-reserved (`ctrl+c` in Global,
Transcript, HistorySearch; `ctrl+d` in Global, Settings, Transcript) = 173.

It is a **complete snapshot of the defaults**, not a stub. Loading it back gives:

```
[keybindings] Loaded 173 user bindings from …/keybindings.json
[keybindings] Reloaded: 352 bindings, 0 warnings
```

Every default now exists twice.

**It never overwrites.** RUN, `$SCRATCH/nooverwrite.sh` — ran `/keybindings`
against a pre-existing 1-binding file:

```
before=4002950b87648b417028e7ac5fe489b667ac0731d46925410e115bfc5c73fdff
after =4002950b87648b417028e7ac5fe489b667ac0731d46925410e115bfc5c73fdff
UNCHANGED
```

and the REPL said "Opened …" rather than "Created … with template".

**Consequences for the resource.** On a `/keybindings`-seeded machine every
default appears as an explicit entry. A `check()` reading "entry present ⇒ user
intent" gets 173 false positives. `ensure = :absent` implemented as "delete the
entry" is a no-op on a default-valued entry and a revert on a genuinely
overridden one. The resource must key on `(context, canonical chord)`, compare
values, and never rewrite the file wholesale.

---

## 8. Defaults are not a fixed set

The default table `pSr` contains computed keys and conditional spreads:

```js
lLo=Kt(), jf_=lLo==="windows"||lLo==="wsl",
Gf_=jf_?"alt+v":"ctrl+v",
Wf_=lLo!=="windows"||(rce()?wHs("1.4.0",">=1.2.23"):wHs(process.versions.node,">=22.17.0 <23.0.0 || >=24.2.0")),
Oud=Wf_?"shift+tab":"meta+m",
pSr=[{context:"Global",bindings:{…}},{context:"Chat",bindings:{…,[Oud]:"chat:cycleMode",…,
  [Gf_]:"chat:imagePaste", ...lLo==="wsl"&&{"ctrl+v":"chat:imagePaste"}, space:"voice:pushToTalk"}},…]
```

- `chat:imagePaste` is `ctrl+v` on Linux/macOS, `alt+v` on Windows/WSL, **both**
  on WSL.
- `chat:cycleMode` is `shift+tab` normally, `meta+m` on Windows without VT mode
  (old Node/Bun). DOC documents this footnote.
- Measured default count on this machine (Linux, current runtime): **179**.

So "restore the default" is not a single cross-platform value. A resource that
tries to represent defaults, or to decide whether a user entry is redundant, has
to do it per-host. Safest posture: never reason about defaults at all — only
about entries the resource itself owns.

---

## 9. Open / unconfirmed

- **Uppercase-implies-Shift**: settled against DOC by code on both sides plus an
  observed normalisation collision (§3.3), but **not by an actual keypress**.
  Worth one manual check before relying on it in docs.
- **Warm backend** (`Cc.state("keybindings")`, §2.3): read from the descriptor
  only. Transport, and whether it can coexist with a local file, not exercised.
- **Torn writes.** Hot reload is confirmed (§2.2), but I did not test whether a
  non-atomic write is observed mid-flight and transiently drops to defaults. If
  the resource writes in place rather than write-temp-then-rename, this matters.
- **`DiffPanel`** is in the runtime context enum but has no default bindings and
  appears in neither DOC nor STORE. Purpose inferred from `DiffDialog` only.
- **`strip:*`** (13 actions) has no default bindings and no documentation
  anywhere. Bindable; effect unverified. Presumably a tab strip
  (cf. `app:toggleReplTab`).
- **macOS-only reserved list** (`k1s`) not exercised — Linux host.
