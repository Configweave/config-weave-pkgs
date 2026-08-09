# 09 — The dangerous-settings consent hash: what it covers, and what it does not

**Question ([#25](https://github.com/Configweave/config-weave-pkgs/issues/25)):**
can a playbook pre-consent to Claude Code's dangerous-settings hash, or is the
re-prompt an unavoidable README limit?

**Source:** the Claude Code CLI binary at
`~/.local/share/claude/versions/2.1.226` (297 831 432 bytes, installed
2026-08-09), with `2.1.204`, `2.1.223`, `2.1.224` and `2.1.225` used for version
cross-checks. All byte offsets below are into **2.1.226** unless stated
otherwise. Two behaviours are backed by observed runs, shown with their command
lines. No documentation was consulted; the public settings page does not
describe this mechanism at all.

## Headline

**The question does not arise, because the hash does not cover anything a
playbook writes.** The dangerous-settings payload is built **exclusively from
remote managed settings fetched over HTTPS from Anthropic** — the response body
of `GET {BASE_API_URL}/api/claude_code/settings` (or, on a Cloud gateway,
`{gateway}/managed/settings`). It is never built from `settings.json` at any
scope, nor from the on-disk `managed-settings.json`. Converging
`statusLine`, `apiKeyHelper`, `env`, `hooks`, `claudeMd` or any of the other
seven keys on disk cannot change the hash, cannot invalidate stored consent and
cannot cause a re-prompt.

| | |
|---|---|
| What the payload is built from | the **remote** settings object only |
| Local `settings.json` (any scope) contribution | **none** |
| Consent store | `$CLAUDE_CONFIG_DIR/remote-settings-consent.json` (default `~/.claude/…`), mode `0600` |
| Comparison source | **both** — `consented_payload` (in-memory/disk cache) *or* `org_record` (the file above), chosen at runtime |
| A managed-settings key that expresses pre-consent | **none exists** |
| Fires in a non-interactive run? | **No** — `deferred_non_interactive`, settings applied, run proceeds |
| Consequence of a stale hash, interactive | blocking modal; **reject exits the process with status 1** |
| Consequence of a stale hash, non-interactive | none visible; settings applied for that run, consent not persisted |
| Bypass env var or flag | **none**; the two injection hooks that would allow one are stubbed dead |
| Resources needing a doc-cell warning about this | **zero**, on current evidence |

This **overturns the central inference of
[#18](https://github.com/Configweave/config-weave-pkgs/issues/18)** (recorded in
`07-settings-key-audit.md`) and the mitigation
[#20](https://github.com/Configweave/config-weave-pkgs/issues/20) built on top
of it. See "Where this overturns 07 and #20" below.

## The mechanism, function by function

All of the following live in one contiguous run at
**276 760 285 – 276 765 500**, plus the ten-key list at **268 661 595**.

### The ten command-valued keys — `cIc`, byte 268 661 595

```js
cIc=["apiKeyHelper","awsAuthRefresh","awsCredentialExport","fileSuggestion",
     "gcpAuthRefresh","otelHeadersHelper","processWrapper","proxyAuthHelper",
     "statusLine","subagentStatusLine"]
```

`07`'s list is exactly right. What `07` did not check is **who reads it**.
`cIc` appears at four byte offsets in the binary: the `var` declaration list
(268 656 872), this assignment (268 661 595), one read (276 760 788), and heap
string-table copies. **The single read is inside `D5e`.** The list exists for no
other purpose than building this payload.

### The payload — `D5e(e)`, byte 276 760 681

Walks `cIc` over the object `e`, accepting a bare string or an object with a
string `.command`, and keeps the value only when it is non-empty. Then:

- `envVars` — every `e.env` entry, `String()`-coerced, kept when non-empty and
  when `Acr(name, value)` is false;
- `hasHooks` / `hooks` — `e.hooks` when it is a non-null object with ≥ 1 key;
- `hasClaudeMd` / `claudeMd` — `e.claudeMd` when it is a non-empty string.

`Acr(e,t)` (byte **268 656 681**) is
`m2g.has(e.toUpperCase()) || (h2g.has(e.toUpperCase()) && _r(t))`.
`m2g` (byte **268 661 778**) is a **183-name** allowlist of benign env vars —
`ANTHROPIC_MODEL`, all the `VERTEX_REGION_*`, all the `OTEL_*`,
`BASH_DEFAULT_TIMEOUT_MS`, and so on — which are excluded from the payload
unconditionally. `h2g` (byte **268 667 707**) is four names —
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_ERROR_REPORTING`,
`DISABLE_TELEMETRY`, `DO_NOT_TRACK` — excluded only when the value is truthy by
`_r` (`1`/`true`/`yes`/`on`).

### Canonicalisation and hash — `gAn` 276 760 285, `Rna` 276 761 493, `Dna` 276 761 609

```js
function gAn(e){if(Array.isArray(e))return e.map(gAn);
  if(e!==null&&typeof e==="object"){let t={};
    for(let r of Object.keys(e).sort())t[r]=gAn(e[r]);return t}return e}
function Rna(e){return De(gAn({shellSettings:e.shellSettings,envVars:e.envVars,
  hooks:e.hooks,claudeMd:e.claudeMd}))}
function Dna(e){return aip.createHash("sha256").update(Rna(e)).digest("hex")}
```

`De` is `JSON.stringify` (byte **267 802 682**:
``function De(e,t,r){using n=p0`JSON.stringify(${e})`;return JSON.stringify(e,t,r)}``).
`gAn` sorts object keys recursively but **preserves array order**.

### The comparison — `sip` 276 761 686, `lip` 276 761 789

```js
function sip(e,t){let r=D5e(e),n=D5e(t);
  if(!Lqt(n))return!1;      // new payload is not dangerous → no prompt
  if(!Lqt(r))return!0;      // old was clean, new is dangerous → prompt
  return Rna(r)!==Rna(n)}   // otherwise: serialised payloads differ?
function lip(e,t){switch(e.source){
  case"consented_payload":return sip(e.settings,t);
  case"org_record":{let r=D5e(t);
    if(!Lqt(r))return!1;
    if(Dna(r)===e.dangerousSettingsHash)return!1;   // hash matches the org record → no prompt
    return sip(e.consentedPayload,t)}}}
```

Note that `sip` compares the **serialised payloads**, not the hashes; `Dna` is
used only for the `org_record` path and for what is written to disk.

## The only two call sites, and what they are given

`D5e` is read at exactly two live sites (a third, byte 296 954 939, is a
name collision inside the bundled Mermaid copy):

1. **`Ksa`, byte 277 044 481** — the remote managed-settings fetch. The
   decisive lines:

   ```js
   let c = s.consentIdentity ? await pip(s.consentIdentity) : null,
       u = Usa(brs()),
       d = c !== null ? {source:"org_record", dangerousSettingsHash:c, consentedPayload:u}
                      : {source:"consented_payload", settings:u},
       p = Usa(a),
       f = await yip(d, p, e.showSecurityDialog);
   ```

   `a` is `s.settings` — the **HTTP response body** from
   `igb()` = `` `${sa().BASE_API_URL}/api/claude_code/settings` `` (or
   `` `${gateway.url}/managed/settings` ``). `Usa(e)` is
   `jpt(e,"remote managed settings").settings ?? {}`. `brs()` is the previously
   consented remote settings held in module state (`ulo`), seeded from the disk
   cache `$CLAUDE_CONFIG_DIR/remote-settings.json` (`g2g`, byte 268 668 649).
   **Both sides of every comparison are remote settings.** No local settings
   source is in scope here.

2. **`fGn`, byte 285 457 107** — the confirmation component. It renders
   `Lna(D5e(settings))` under the title *"Managed settings require approval"*
   and the body *"Your organization has configured managed settings that could
   allow execution of arbitrary code or interception of your prompts and
   responses."*, with buttons *"Yes, I trust these settings"* / *"No, exit
   Claude Code"*. Same `settings` object — the fetched remote payload.

The whole feature is gated behind `D0e()` (byte **272 896 078**), which returns
false unless the install is first-party (`Kn()==="firstParty"` and
`ANTHROPIC_BASE_URL` is `api.anthropic.com` or unset) **and** the user is a
logged-in claude.ai account (or has an API key), and which is hard-false for
entrypoints `local-agent`, `remote_cowork` and `claude-coworker*`. On Bedrock,
Vertex, Foundry, Mantle or any proxied `ANTHROPIC_BASE_URL`, remote settings —
and therefore this entire gate — are off.

## 1. Where the stored consent is written

`$CLAUDE_CONFIG_DIR/remote-settings-consent.json` — `uip()`, byte
**276 762 265**: `cip.join(Ln(), Ecb)` with
`Ecb="remote-settings-consent.json"` (string at byte 276 763 728). `Ln()` is the
user-scope Claude config directory: `fen("userSettings")` resolves to
`NH.resolve(Ln())` (`fen`, byte **268 801 856**), i.e. the directory `settings.json`
itself lives in.

*Observed*: with `CLAUDE_CONFIG_DIR=$H2/cfg`, a run of
`env -i HOME=… CLAUDE_CONFIG_DIR=$H2/cfg ANTHROPIC_API_KEY=k ANTHROPIC_BASE_URL=http://127.0.0.1:1 claude -p hi --debug`
created `debug/`, `sessions/`, `projects/`, `backups/` and `.claude.json`
under `$H2/cfg` and left `$HOME/.claude` non-existent. So the path is
`$CLAUDE_CONFIG_DIR/remote-settings-consent.json`, defaulting to
`~/.claude/remote-settings-consent.json`.

**Schema** (`Tcb`/`Ccb`, byte **276 763 872**):

```json
{ "version": 1,
  "records": {
    "<organizationUuid>": { "accountUuid": "<uuid>",
                            "dangerousSettingsHash": "<sha256 hex>",
                            "updatedAt": 1723200000000 } } }
```

Written by `fip` (byte **276 762 945**) with `ws().atomicWrite(…, 384)` — mode
`0o600`. It keeps at most **20** records (`wcb`), evicting oldest-`updatedAt`
first, and skips the rewrite entirely when the hash is unchanged and
`updatedAt` is less than **24 h** old (`Acb=86400000`). A file whose `version`
is greater than 1 is treated as "from a newer version" and **not overwritten**
(log: `Remote settings: Consent records file is from a newer version; not overwriting it`).
Read by `dip`/`pip` (bytes 276 762 312 / 276 762 788); `pip` returns the stored
hash only when the record's `accountUuid` matches the currently logged-in
account.

**Is it convergeable?** Mechanically, yes — it is a plain 0600 JSON file in the
user config dir with a stable schema, and this package could write it. Usefully,
**no**: the value that has to go in it is the SHA-256 of the *org's* remote
settings payload, which is served by Anthropic, is not visible on disk before
the first fetch, and changes whenever the org admin changes it. A playbook
cannot compute it, and a wrong value is indistinguishable from no record at all
(`lip` falls through to `sip(e.consentedPayload, t)`). Writing the file is
therefore not a resource; it is a way to pin a hash you would have had to
observe first.

## 2. `consented_payload` or `org_record`?

**Both, selected at runtime.** `Ksa` picks `org_record` when
`pip(consentIdentity)` returns a hash — that is, when
`remote-settings-consent.json` already holds a record for this
`organizationUuid` **and** its `accountUuid` matches the current login — and
`consented_payload` otherwise. `consentIdentity` is only populated for
claude.ai OAuth logins whose credentials are in the `store` (`Gsa`, byte
**277 040 505**: `if(Ysa()!=="store")return;`), so API-key and gateway installs
always take the `consented_payload` branch.

`consented_payload` is per-machine and lives in memory for the process, seeded
from `$CLAUDE_CONFIG_DIR/remote-settings.json`. `org_record` is per-machine too
— the "org" in the name refers to the *key*, not to a server-side record. There
is no server-side consent state involved in the check.

**No managed-settings key expresses pre-consent.** The 155-key schema audited in
`07` contains nothing that suppresses this dialog. `forceRemoteSettingsRefresh`
— the one managed key that touches this path — makes it **worse**, not better:
at byte **290 502 393** the CLI's `preAction` reads

```js
if(tn("policySettings")?.forceRemoteSettingsRefresh && !f){
  let g = await PVo(async()=>LVo(await e.showSecurityDialog?.()));
  if(!g.valid) return Ws(g.message) }
else if(Kn()==="gateway" && !f){ … await LVo(…) }
else Promise.resolve(e.showSecurityDialog?.()).then((g)=>LVo(g)).catch(He);
```

so the default is a fire-and-forget background refresh, and
`forceRemoteSettingsRefresh` (plus any Cloud gateway install) turns it into a
**blocking, awaited** startup step. If `managed_policy` gains a param for that
key, that is the sentence its doc cell needs — not a consent-hash warning.

## 3. Does it fire in a non-interactive run?

**No.** `yip` (byte **276 764 689**), third statement:

```js
async function yip(e,t,r){
  if(!t||!Lqt(D5e(t)))return"no_check_needed";
  if(!lip(e,t))return"no_check_needed";
  if(!i2())return"deferred_non_interactive";
  …
}
function _ip(e){switch(e){
  case"rejected":return od(1),!1;
  case"deferred_no_consent_surface":return!1;
  case"approved":case"no_check_needed":case"deferred_non_interactive":return!0}}
```

`i2()` (byte **267 391 947**) is `return or.isInteractive`. That flag is set
once, in `yLh` (byte **290 051 756**):

```js
function yLh({interactivity:e}){let t=process.argv.slice(2),
  r=e.kind==="non-interactive"||yWE(t); if(r)G3e(); _Wi(!r); … }
function yWE(e){let t=e.includes("-p")||e.includes("--print"),
  r=e.includes("--init-only"),n=e.some((o)=>o.startsWith("--sdk-url"));
  return t||r||n||!process.stdout.isTTY}
```

So `isInteractive` is false — and the gate returns `deferred_non_interactive` —
for **every** one of: `claude -p` / `--print`; `--init-only`; any `--sdk-url*`
(SDK/headless); and, independently of argv, **any run whose stdout is not a
TTY**, which covers piped stdin, `nohup`, systemd units, CI and everything a
config-weave playbook or a vmlab test does. `--dangerously-skip-permissions`
does not appear in this path at all and is irrelevant to it. An ordinary TUI
start on a TTY is the only entry point that reaches the dialog.

`deferred_non_interactive` maps to **true** in `_ip`, and `Ksa` handles it
explicitly:

```js
case"deferred_non_interactive":
  w("Remote settings: Applied for this non-interactive run; consent deferred — not persisting the disk cache as consented"),
  ve("remote_managed_settings_pull",{status:Ce("applied_consent_deferred")});
```

The unconsented remote settings are **applied in full** for that run. The only
consequence is that the disk cache is not marked consented, so the next
interactive start will still ask. This is the same shape as
[#15](https://github.com/Configweave/config-weave-pkgs/issues/15)'s hook trust
gate, and the same conclusion follows: the unattended case a playbook creates is
unaffected.

Byte-identical in **2.1.223** (offset 270 192 624 – 500), **2.1.224**
(274 682 641 – 420) and **2.1.226**; only minifier aliases differ (`bB()`,
`qF()`, `i2()`).

## 4. Does converging a key to the value it already has change the hash?

Not applicable to local settings, since they never enter the payload. For the
remote payload, the answer is **no, and the normalisation is unusually
forgiving** — with one exception.

Method: the binary's own `gAn`, `D5e`, `Lqt`, `Rna`, `Dna`, `sip`, `lip`, `Lna`,
`Acr`, `_r`, `cIc`, `m2g` and `h2g` were carved out of 2.1.226 **verbatim** by
byte range, wrapped with `De = JSON.stringify` and `require("crypto")`, and
exercised in Node 26. The script is reproducible from the offsets above.

| Probe | Result |
|---|---|
| Object key order in `env` / at top level | **irrelevant** — `gAn` sorts recursively |
| `statusLine:"/x.sh"` vs `{type:"command",command:"/x.sh",padding:0}` | **identical hash** — only `.command` is extracted |
| absent vs `""` vs `null` for any of the ten | **identical** |
| `env:{FOO:1}` vs `env:{FOO:"1"}` | **identical** — `String()` coercion |
| `env:{ANTHROPIC_MODEL:"x"}` vs no env | **identical** — 183-name allowlist |
| `env:{DO_NOT_TRACK:"1"}` vs no env | **identical** |
| `env:{DO_NOT_TRACK:"0"}` vs no env | **differs** — the `h2g` exclusion is truthiness-gated |
| `hooks:{}` vs no `hooks` | **identical** |
| key order *inside* a hooks object | **irrelevant** |
| **element order inside a hooks array** | **differs** — `gAn` maps arrays, it does not sort them |

Sample serialisation, showing the sorted top level:

```
{"claudeMd":"md","envVars":{"A":"2","Z":"1"},"hooks":{"X":[1]},"shellSettings":{"statusLine":"/x.sh"}}
```

Consequences worth carrying forward even though they do not bite here:

- The reformat-on-first-apply behaviour this package's settings resources have
  (rewriting the file with sorted keys) is **hash-neutral by construction** —
  `gAn` sorts anyway. If the hash ever did cover local settings, key-order
  churn still would not perturb it.
- **Array order is the one live hazard.** A resource that rebuilt
  `hooks.<event>[]` in a different order would change a payload hash. That is
  worth remembering for `hook`'s element-merge design regardless of this
  ticket, because it is the same property that makes hook arrays
  order-significant to the hook runner.
- `statusLine`'s cosmetic leaves (`padding`, `refreshInterval`,
  `hideVimModeIndicator`) are invisible to the payload; only `command` counts.

The scope-merge sub-question resolves trivially: there is no scope merging in
this path. `Usa()` is applied to one settings object — the remote one — never to
a merged view, so a `:project` write cannot perturb a `:user`-scoped anything.

## Consequence of a stale hash

Three distinct outcomes, from `_ip` (byte 276 765 407) and `Ksa`'s switch:

| Outcome | When | Effect |
|---|---|---|
| `deferred_non_interactive` | `!i2()` | New settings **applied**, run continues, cache not marked consented. A debug line, no user-visible warning. |
| `approved` | user picks *"Yes, I trust these settings"* | Applied, cache marked consented, `fip` records the hash. |
| `rejected` | user picks *"No, exit Claude Code"* | `od(1)` — **the process exits with status 1.** `Ksa` also logs `Remote settings: User rejected new settings, using cached settings`. |
| `deferred_no_consent_surface` | interactive, but no dialog host and `r===void 0` | Falls back to the **previously consented** settings; the new remote settings are discarded for this run. |

So it is never a silent downgrade of the command-valued keys and never a mere
warning: interactively it is a blocking modal whose "no" is a hard exit, and
non-interactively it is invisible and permissive.

## Bypasses: there are none, and the two that look like bypasses are dead

- **`CLAUDE_CODE_REMOTE_SETTINGS_PATH`.** `Ksa`'s second statement is
  `let t=ize(); if(t) return … "Using override file … skipping API fetch"` —
  which *would* skip the consent check entirely. But `ize()` (byte
  **268 668 141**) is literally `function ize(){return}`. Same in 2.1.223, where
  the same function is `function ABe(){return}` (byte **262 406 254**). The env
  var is still registered in the env-var table and still named in the log
  string; it does nothing in a shipped build.
- **`CLAUDE_CODE_MOCK_REMOTE_SETTINGS`.** `lgb`'s first statement is
  `let r=await sgb(); if(r)return r`, and `sgb` (byte **277 039 931**) is
  `async function sgb(){return null}`.
- **Endpoint redirection.** `sa().BASE_API_URL` is chosen by `Xdc()` (byte
  **267 904 201**), which is `function Xdc(){return"prod"}` — the local and
  staging branches are unreachable. `CLAUDE_CODE_CUSTOM_OAUTH_URL` is checked
  against an allowlist (`cno`) and throws otherwise. Setting
  `ANTHROPIC_BASE_URL` elsewhere does not redirect the settings fetch; it turns
  the whole feature **off** via `hf()`.
- **No settings key and no CLI flag** suppresses the dialog.

The only *supported* way to be certain the gate never fires is to be on a
provider where `D0e()` is false — Bedrock, Vertex, Foundry, Mantle, or a proxied
`ANTHROPIC_BASE_URL` — which is a deployment fact, not a package feature.

## Observed runs

Two runs against a throwaway `HOME`, with a user `settings.json` containing
**all ten** command-valued keys plus `env` and `hooks`. The user's real
`~/.claude` and `~/.claude.json` were never read or written.

```
# non-interactive
env -i HOME=$H PATH=/usr/bin:/bin TERM=dumb CLAUDE_CODE_ENTRYPOINT=cli \
  ANTHROPIC_API_KEY=sk-ant-not-a-real-key ANTHROPIC_BASE_URL=http://127.0.0.1:1 \
  claude -p 'say hi' --debug
```

Result: startup completed, `$H/.claude/{debug,sessions,projects,backups}` and
`$H/.claude.json` created, **no `remote-settings.json`, no
`remote-settings-consent.json`**, and **no `Remote settings:` line anywhere in
the debug log** — consistent with `D0e()` false for a non-first-party base URL.
The run then looped on API connection errors (expected; the endpoint is dead)
and was killed.

```
# interactive, on a pty
script -qec "env -i HOME=$H … TERM=xterm-256color claude --debug" /dev/null
```

Result: reached the first-run theme picker; the string
`Managed settings require approval` never appeared, and no consent file was
created.

**Both runs are weak evidence and are labelled as such.** They confirm the
negative (nothing local triggers it) but cannot confirm the positive, because —
see "Bypasses" — the consent path is unreachable without a real first-party
org that actually serves remote managed settings. **The positive path was not
staged.** Every claim about what happens when the hash *does* go stale is code
reading, cross-checked across three builds, not observation.

## Version cross-check

| String | 2.1.204 | 2.1.223 | 2.1.224 | 2.1.225 | 2.1.226 |
|---|---:|---:|---:|---:|---:|
| `Managed settings require approval` | 2 | 2 | 2 | 2 | 2 |
| `deferred_non_interactive` | 0 | 5 | 5 | 5 | 5 |
| `dangerousSettingsHash` | 0 | 0 | 8 | 8 | 8 |
| `consented_payload` / `org_record` | 0 | 0 | 4 | 4 | 4 |
| `remote-settings-consent.json` | 0 | 0 | 2 | 2 | 2 |
| `Consent records file is` | 0 | 0 | 2 | 2 | 2 |

Three generations, then: **2.1.204** has the dialog with no deferral and no
hash; **2.1.223** adds the non-interactive deferral; **2.1.224** adds the
SHA-256 hash, the `consented_payload`/`org_record` split and the on-disk consent
record. The 2.1.224 implementation of `D5e`/`Lqt`/`Rna`/`Dna`/`sip`/`lip`/`Lna`
(byte **274 678 969** ff., aliases `yGe`/`nWt`/`nQs`/`oQs`/`RJd`/`LJd`/`iQs`) is
**token-for-token identical** to 2.1.226's modulo minifier names, as is the
consent-file writer. Since this whole subsystem is three weeks old and changed
shape twice in that window, treat it as **volatile** and re-check at
implementation time.

## Where this overturns 07 and #20

`07-settings-key-audit.md`'s closing section, "The dangerous-settings consent
hash — new in this audit", is right about every identifier and wrong about the
input. It says:

> **This is a real constraint on the package.** Converging *any* of those ten
> keys, or `env`, or `hooks`, or `claudeMd`, changes the hash and **invalidates
> the user's prior consent**, so the next interactive start re-prompts. That
> touches `auth`, the new `status_line`, `ui.fileSuggestion`, `env_var`, `hook`
> and `managed_policy.claudeMd` — six resources. It belongs in the README's
> known limits and in each of those resources' doc cells.

Three errors, in increasing order of consequence:

1. **The input is wrong.** `07` traced `cIc → D5e → Rna → Dna → sip/lip` and
   stopped. It never established what object is passed to `D5e`. The answer is
   `Usa(a)` where `a` is an HTTP response body. Nothing on disk under the
   package's control reaches it. `07` was reading the mechanism correctly and
   guessing the subject.
2. **"the next interactive start re-prompts" understates the interactive
   consequence and overstates the unattended one.** Rejecting is `od(1)` — an
   exit, not a re-prompt you can dismiss — and non-interactively there is no
   prompt at all, which `07` did not check even though `07` is contemporaneous
   with #15's finding that the hook gate behaves the same way.
3. **The six-resource blast radius is empty.** No doc cell needs this warning
   and the README needs no such known limit.

**[#20](https://github.com/Configweave/config-weave-pkgs/issues/20)'s mitigation
should be reverted.** It settled that `status_line`'s doc cell states the
re-prompt. On this evidence that sentence is false and should be deleted rather
than softened: it would tell an author that setting `statusLine` has a
consequence it does not have, and — worse for a config-weave package — imply
that a converge is not idempotent when it is.

`07`'s other correction stands untouched: there really are **ten**
command-valued keys, not #13's four, and #10's "the resource manages the
setting, never the script" rule really does have to reach all ten. That
conclusion never depended on the consent hash; it follows from the keys holding
shell commands.

## Uncertain — flagged rather than guessed

- **The positive path is unobserved.** Everything about what a real stale-hash
  prompt looks and behaves like is read from `yip`/`_ip`/`Ksa` in three builds.
  A first-party account in an org that serves remote managed settings would
  settle it; this machine cannot.
- **`Gsa`/`Ysa()!=="store"`.** The claim that API-key and gateway installs never
  take the `org_record` branch rests on reading `Gsa` (`if(Ysa()!=="store")return;`)
  and `agb`'s three-way auth selection (byte **277 040 112**). `Ysa` itself
  (byte 281 769 320) was not
  fully traced. Low stakes — both branches are per-machine and neither is
  pre-consentable — but it is an inference.
- **Whether an org admin can pre-seed consent server-side.** The response schema
  `bip` is `Se({uuid:$(),checksum:$(),settings:Wn($(),po())})` (byte **276 765 706**) with no consent
  field, and nothing in the client reads a server-side consent flag. That is
  strong evidence of absence, not proof; only the server knows what it could
  send.
- **Whether a future build extends the payload to local settings.** The
  subsystem is three weeks old. `D5e` takes an arbitrary settings-shaped object
  and would work unchanged on a merged local view. Nothing prevents Anthropic
  from wiring one in. This is the single reason to keep a line about the
  mechanism *somewhere* in the package's notes, even though it currently
  constrains nothing.
- **`policySettings` divergence is a different mechanism** and was not
  investigated in depth. `capturePolicySnapshot`/`hasPolicyDiverged` (byte
  **285 459 478**) deep-compare the on-disk managed settings against a startup
  snapshot and, on the gateway post-login path, trigger `execRelaunch()`. If
  `managed_policy` converges `/etc/claude-code/managed-settings.json` while a
  session is live, **that** is the behaviour to characterise — a relaunch, not a
  consent prompt. Worth its own ticket.

## What this means for the six resources

| Resource | What #18/#20 implied it needed | What it actually needs |
|---|---|---|
| `auth` (5 of the ten keys, +`processWrapper`, `otelHeadersHelper` per `07` = 7) | consent-hash warning in the doc cell | **nothing new.** #10's command-valued rule already covers it. |
| `status_line` (`statusLine`, `subagentStatusLine`) | doc cell states the re-prompt (#20's settled mitigation) | **delete that sentence.** It is false. |
| `ui` (`fileSuggestion`) | consent-hash warning | nothing new |
| `env_var` (`env`) | consent-hash warning | nothing new |
| `hook` (`hooks`) | consent-hash warning | nothing new — but see the array-order note above, which is a real property of hook merging and survives this ticket |
| `managed_policy` (`claudeMd`) | consent-hash warning | nothing about consent. If it gains a `forceRemoteSettingsRefresh` param, that param's doc cell should say it converts the background remote-settings refresh into a **blocking** startup step that can prompt or exit. |

**New README known limits: none from this ticket.** The one candidate — "Claude
Code may prompt for consent when your organization's remote managed settings
change" — is a fact about the user's org, not about anything this package
writes, and putting it in the README would repeat #18's error in prose.
