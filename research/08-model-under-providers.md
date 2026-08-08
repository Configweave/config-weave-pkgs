# The `model` settings key under third-party providers

Research for issue #19 (does the `model` section resource work on Bedrock /
Vertex / Foundry, or do those providers force `ANTHROPIC_MODEL`?).

Sources, in order of authority:

- **BIN** — `/home/wil/.local/share/claude/versions/2.1.225` (Claude Code
  2.1.225, `GIT_SHA d4b76e8c52c2391af51b60cc71a513246c40a129`,
  `BUILD_TIME 2026-08-07T19:37:58Z`). Minified JS bundle; all snippets are
  `grep -a` output quoted verbatim, minified names preserved.
- **RUN** — end-to-end runs in a throwaway `HOME` (`mktemp -d`) against a
  **stub provider endpoint** on `127.0.0.1:18101` that logs the request path
  and `body.model` and answers `400`. The real `~/.claude/` was read-only
  throughout and was never the `HOME` of any run. Every run set
  `AWS_EC2_METADATA_DISABLED=1` (per #13's note) and a 45 s `timeout`.
- **DOC** — <https://code.claude.com/docs/en/model-config> and
  <https://code.claude.com/docs/en/amazon-bedrock>.

The stub is the whole trick: because the provider SDKs put the model id in the
**URL path** (Bedrock `/model/<id>/invoke-with-response-stream`, Vertex
`/projects/<p>/locations/<r>/publishers/anthropic/models/<id>:streamRawPredict`)
or in `body.model` (Foundry `/v1/messages`), the exact string Claude Code
resolved is directly observable without credentials or network.

---

## 0. The answer

**`model` is honoured under every third-party provider.** It is not ignored,
not overridden by provider selection, and does not require `ANTHROPIC_MODEL`.
There is one resolution path for the main-loop model and it is
provider-independent; the provider only decides how the resolved value is
*translated* on the way out.

`ANTHROPIC_MODEL` outranks `model`, but that is equally true on first-party
auth — it is not a third-party carve-out. **#13's split holds.**

The scope limit that *does* need documenting is narrower and was not the one
the ticket anticipated: **which spellings `model` accepts**. A plain alias
(`opus`) and a *catalogue-exact* Anthropic model id (`claude-opus-5`,
`claude-sonnet-4-5-20250929`) are translated to the provider's id. A
**near-miss id — the undated marketing spelling of a dated model, e.g.
`claude-sonnet-4-5` or `claude-haiku-4-5` — is silently passed through
verbatim** and reaches Bedrock as an id Bedrock will reject. That is the
"reports green and does nothing" failure mode the ticket was worried about,
relocated from the key to its value.

---

## 1. The precedence chain

Ordered, highest first. Rungs 1–5 select the **requested** model string; rungs
6–8 translate it into what goes on the wire.

### 1. In-session override — `nT()`

```js
function nT(){return or.mainLoopModelOverride}
```

Set by `/model` (`kw()`), by the refusal-fallback latch, and by the Mantle
`adminPin`/`pinRefuted` paths in `egb()`. Not reachable from a config file, but
it is the top of `pW()` and therefore the reason a converged `model` value can
be live-overridden without the file changing. — BIN.

### 2. CLI `--model` — via `$Eu()` → `$J()`

```js
function $J(){return or.initialMainLoopModel}
```

```js
function $Eu(e){let{cli:t,env:r,settings:n,agentFrontmatter:o}=e,
 i=t.model==="default"?_0():t.model,s=i,a=o?.model,l;
 if(!i&&a&&a!=="inherit")l=a,i=ns(a),s=a;
 let c=!1,u=i;
 if(u===void 0)u=r.ANTHROPIC_MODEL||Vwy(n.model||void 0,t.isNonInteractiveSession===!0)||void 0,s=u;
 …}
```

`$Eu` is the startup resolver and its order is explicit in that one line:
`cli.model` → agent frontmatter `model` → `env.ANTHROPIC_MODEL` → `settings.model`.
— BIN.

**RUN** — settings `model: "opus"`, settings-`env` `ANTHROPIC_MODEL: "sonnet"`,
launched `claude --model haiku -p 'hi'` under Bedrock:

```
POST /model/us.anthropic.claude-haiku-4-5-20251001-v1:0/invoke-with-response-stream
```

The flag won over both.

### 3. Agent frontmatter `model:` (subagents / `--agent`)

`o?.model` in `$Eu`, above `ANTHROPIC_MODEL`. Not exercised by RUN; claim rests
on the source line. — BIN.

### 4. `ANTHROPIC_MODEL`

```js
function pW(){let e,t=nT();if(t!==void 0)e=t;else{let r=$J(),n=process.env.ANTHROPIC_MODEL;
 e=r!==void 0?r:n||Js()?.model||void 0}return Wyo(e)}
```

`n||Js()?.model` — the env var is consulted first, the settings key second.
— BIN.

**RUN** — settings `model: "opus"` + process-env
`ANTHROPIC_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0`, Bedrock:

```
POST /model/us.anthropic.claude-haiku-4-5-20251001-v1:0/invoke-with-response-stream
```

**RUN** — same but `ANTHROPIC_MODEL: "sonnet"` inside the settings `env` block
(i.e. `env_var`'s route, not the shell's):

```
POST /model/us.anthropic.claude-sonnet-4-5-20250929-v1:0/invoke-with-response-stream
```

Two facts here: `ANTHROPIC_MODEL` beats `model` from either source, **and** it
accepts aliases, so it is not a provider-id-only knob.

DOC agrees and states the order plainly: "listed in order of priority: 1.
During session `/model` … 2. At startup `claude --model` … 3. Environment
variable `ANTHROPIC_MODEL` … 4. Settings: configure permanently in your
settings file using the `model` field".

### 5. The `model` settings key — `Js()?.model`

```js
Js=Co;
function Co(){return Ace().settings||{}}
function Pge(e){let t=fT();for(let r=t.length-1;r>=0;r--){let n=t[r];if(tn(n)?.[e]!==void 0)return n}return null}
```

`Js` is an alias for `Co`, the **merged effective settings** across all scopes,
so `model` participates from enterprise/project/user/local exactly like any
other key, and `Pge("model")` names the winning scope. There is **no** `Kn()`
(provider) test anywhere in `pW()` or `$Eu()`. — BIN.

**RUN**, the headline result — throwaway `HOME`,
`~/.claude/settings.json` = `{"model":"opus","env":{"CLAUDE_CODE_USE_BEDROCK":"1",…}}`:

```
GET  /inference-profiles?type=SYSTEM_DEFINED
POST /model/us.anthropic.claude-opus-5/invoke-with-response-stream
```

Same file with `"model":"sonnet"`:

```
POST /model/us.anthropic.claude-sonnet-4-5-20250929-v1:0/invoke-with-response-stream
```

Vertex (`CLAUDE_CODE_USE_VERTEX`, `"model":"opus"`):

```
POST /projects/proj123/locations/us-east5/publishers/anthropic/models/claude-opus-5:streamRawPredict
```

Foundry (`CLAUDE_CODE_USE_FOUNDRY`, `"model":"opus"`):

```
POST /v1/messages?beta=true  body.model=claude-opus-4-6
```

Three providers, three different wire forms, all driven by the settings key
alone. (Foundry resolving `opus` to 4.6 rather than 5 is the catalogue's
per-provider alias table, §3.)

### 6. Fallback when nothing pinned — `_0()` / `x2()` / `Ppu()`

```js
function ls(){let e=pW();if(e!==void 0&&e!==null)return ns(e);return _0()}
function _0(){return ns(x2())}
function x2(){return kpr().setting}
```

`kpr()` layers org default → `Ppu()` tier default → `Yyo()`
(`enforceAvailableModels`) → `Kyo()` (entitlement). `Ppu()`'s third-party arm:

```js
if(e==="bedrock"||e==="vertex"){let t=Ipu(),r=…;
 if(t.sonnet&&!t.opus&&!r)return{setting:uk(),envFamily:"sonnet"};
 return{setting:Rw(),envFamily:"opus"}}
```

**RUN** — no `model` key at all, Bedrock: `POST /model/us.anthropic.claude-opus-5/…`.

### 7. Alias resolution — `ns()`, and where `ANTHROPIC_DEFAULT_*_MODEL` enters

```js
function ns(e){let t=e.trim(),r=t.toLowerCase(),n=wS(r),o=n?Aa(r).trim():r;
 if(NL(o))switch(o){
  case"fable":{let i=wnn();return FL(i+(n&&!Hce()&&!wS(i)?"[1m]":""))}
  case"opusplan":return n?FL(pY(uk())):uk();
  case"sonnet":return n?FL(pY(uk())):uk();
  case"haiku":return n?FL(pY(G7e())):G7e();
  case"opus":return n?FL(pY(Rw())):Rw();
  case"best":return Rpu();default:}
 …return FL(t)}
```

and the four family getters:

```js
function Rw(){let e=te.ANTHROPIC_DEFAULT_OPUS_MODEL;if(e!==void 0)return FL(e);return z7e()}
function uk(){let e=te.ANTHROPIC_DEFAULT_SONNET_MODEL;if(e!==void 0)return FL(e);return jyo()}
function G7e(){let e=te.ANTHROPIC_DEFAULT_HAIKU_MODEL;if(e!==void 0)return FL(e);return Gms()}
function wnn(){let e=process.env.ANTHROPIC_DEFAULT_FABLE_MODEL||zms();return FL(Hce()?xQ(e):e)}
function z7e(e=Eg()){return Vyo("opus",e)??e.opus5}
```

`FL` is the identity function (`function FL(e){return e}`), so the env value is
taken raw. Note `NL(o)` gates the switch: a **non-alias** value falls through to
`return FL(t)` — `ns()` does **not** translate concrete ids at all. That is
rung 8's job.

### 8. Provider translation — `Bce()`, applied at the request

Every outbound request builds `{model:Bce(…)}`:

```js
let vo={model:Bce(i.model),messages:wt,system:se,tools:q7u(ue,i.model),…}   // main loop
let K=dd(t),j={model:Bce(t),max_tokens:a,…}                                 // side queries
```

```js
function Bce(e){let t=dd(e),r=t.toLowerCase();
 if(!Object.hasOwn(wAe,r))return t;                 // ← unknown id: passthrough
 let n=wAe[r];if(n===void 0)return t;
 let o=Rze()[n];
 if(Xyo().state==="refused")return t;
 let s;try{s=tn("policySettings")}catch{return t}
 let a=s?.availableModels,l=s?.modelOverrides??Jpt()??{},c,u;
 if(a===void 0)c=Eg()[n],u=c!==o;
 else{if(!Ec(r,{allowlist:a,overridesMap:l,envFreeAliasResolution:!0}))return t;
      let p=Gby(l,n);c=p??o,u=p!==void 0}
 let d=Kn();
 if(u||d!=="foundry"&&Oc[n][d]!==null)return dd(c);
 return t}
```

`wAe` is the recognised-id map, and its **keys are `provider_ids.first_party`**,
not the catalogue's short `id`:

```js
wAe=Object.fromEntries(Object.entries(Oc).map(([e,t])=>[t.firstParty,e]))
```

`Eg()` is the provider's id table with `modelOverrides` folded in; `Rze()` is
the same table without them:

```js
function Eg(){let e=wOt();if(e===null)return BZc(),NZc(prn(Kn()));return NZc(e)}
function NZc(e){let t=Co().modelOverrides;if(!t)return e;let r={...e};
 for(let[n,o]of Object.entries(t)){let i=wAe[n];if(i&&o)r[i]=FL(o)}return r}
```

Note the `d!=="foundry"` clause: on Foundry, a concrete id is **not** remapped
unless a `modelOverrides` entry covers it. Confirmed — **RUN** Foundry with
`"model":"claude-sonnet-4-5-20250929"` sent `body.model=claude-sonnet-4-5-20250929`,
not Foundry's `claude-sonnet-4-5`.

---

## 2. What `model` accepts — and the one trap

All **RUN**, Bedrock, stub endpoint, settings-`env` provider selection.

| `model` value | wire model id | verdict |
|---|---|---|
| `opus` | `us.anthropic.claude-opus-5` | alias → provider id |
| `sonnet` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | alias → provider id |
| `claude-opus-5` | `us.anthropic.claude-opus-5` | catalogue id → translated |
| `claude-opus-4-6` | `us.anthropic.claude-opus-4-6-v1` | catalogue id → translated |
| `claude-sonnet-5` | `us.anthropic.claude-sonnet-5` | catalogue id → translated |
| `claude-sonnet-4-5-20250929` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | catalogue id → translated |
| `claude-haiku-4-5-20251001` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | catalogue id → translated |
| **`claude-sonnet-4-5`** | **`claude-sonnet-4-5`** | **passthrough — broken on Bedrock** |
| **`claude-haiku-4-5`** | **`claude-haiku-4-5`** | **passthrough — broken on Bedrock** |
| `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | unchanged | provider-native passthrough — correct |

So the answer to "plain alias or the provider's own id?" is **either, plus the
catalogue-exact Anthropic id — but not the undated spelling of a dated model.**

The recognised set is exactly the 17 `provider_ids.first_party` strings in the
catalogue (BIN, `grep -ao 'first_party:"claude-[a-z0-9-]*"' | sort -u`):

```
claude-3-5-haiku-20241022   claude-3-5-sonnet-20241022  claude-3-7-sonnet-20250219
claude-fable-5              claude-haiku-4-5-20251001   claude-mythos-5
claude-opus-4-1-20250805    claude-opus-4-20250514      claude-opus-4-5-20251101
claude-opus-4-6             claude-opus-4-7             claude-opus-4-8
claude-opus-5               claude-sonnet-4-20250514    claude-sonnet-4-5-20250929
claude-sonnet-4-6           claude-sonnet-5
```

Newer models are undated, older ones dated — so `claude-opus-4-6` is right and
`claude-sonnet-4-5` is wrong, from the *same* naming instinct. That is what
makes it a trap rather than a typo.

DOC states the rule for `modelOverrides` keys — "Keys must be Anthropic model
IDs as listed in the Models overview. For dated model IDs, include the date
suffix exactly as it appears there. Unknown keys are ignored." — and the same
`wAe` lookup gates `model`, but DOC never says so about the `model` key itself.

DOC does warn that no validation exists on this path: "The check also doesn't
cover the `--model` flag, the `ANTHROPIC_MODEL` environment variable, or the
`model` setting; a mistyped value there produces *There's an issue with the
selected model* on the first request." Confirms **there is no validate-time or
check-time signal** — the resource cannot detect this itself.

---

## 3. `ANTHROPIC_DEFAULT_*_MODEL` vs `model`, `modelOverrides` and `fallbackModel`

**It is an alias remap, not an override of `model`, and not a fallback.**

From §1 rung 7: the family getters sit *inside* `ns()`'s alias switch. They
change what `opus`/`sonnet`/`haiku`/`fable` resolve to; they never displace a
`model` value that is already concrete.

**RUN** — `"model":"opus"` + `ANTHROPIC_DEFAULT_OPUS_MODEL=arn:aws:bedrock:us-east-1:1234:application-inference-profile/myopus`:

```
POST /model/arn:aws:bedrock:us-east-1:1234:application-inference-profile%2Fmyopus/invoke-with-response-stream
```

The `model` key was still honoured — it named the alias; the env var supplied
the target. Setting `model` to a concrete id instead leaves the env var inert
for that session.

DOC matches: "`ANTHROPIC_DEFAULT_SONNET_MODEL` / … : control what the Default
option and the `sonnet`, `opus`, `haiku`, and `fable` aliases resolve to".

### Relationship to `modelOverrides`

`modelOverrides` is the **typed, per-version form of the same idea**, and the
env vars are *not* merely its env spelling — they are family-level and coarser.
DOC: "The family-level environment variables above configure one model ID per
family alias. If you need to map several versions within the same family to
distinct provider IDs, use the `modelOverrides` setting instead."

Schema (BIN):

```
modelOverrides:Wn($(),$()).optional().describe('Override mapping from Anthropic model ID
(e.g. "claude-opus-4-6") to provider-specific model ID (e.g. a Bedrock inference profile
ARN). Typically set in managed settings by enterprise administrators.')
```

Precedence between them, **RUN**, all Bedrock:

| setup | wire id |
|---|---|
| `model:"claude-opus-5"` + `modelOverrides{claude-opus-5:MYARN-opus}` | `MYARN-opus` |
| `model:"opus"` + `modelOverrides{claude-opus-5:MYARN-opus}` | `MYARN-opus` |
| `model:"opus"` + `modelOverrides{claude-opus-5:MYARN}` + `ANTHROPIC_DEFAULT_OPUS_MODEL=ENVOPUS` | `ENVOPUS` |
| `model:"opus"` + `modelOverrides{claude-opus-5:MYARN}` + `ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5` | `MYARN` |
| `ANTHROPIC_MODEL=claude-opus-5` + `modelOverrides{claude-opus-5:MYARN}` | `MYARN` |
| `model:"claude-sonnet-4-5"` + `modelOverrides{claude-sonnet-4-5:MYSONNET}` | `claude-sonnet-4-5` (key ignored) |
| `model:"claude-sonnet-4-5-20250929"` + `modelOverrides{…-20250929:MYSONNET}` | `MYSONNET` |

So: `ANTHROPIC_DEFAULT_*_MODEL` wins the *alias*, but its **value then goes
through `modelOverrides`** if the value is itself a recognised Anthropic id
(rows 3 vs 4 — `ENVOPUS` is opaque and passes through, `claude-opus-5` is
mapped). DOC states this and dates it: "Overrides also apply when you pass an
Anthropic model ID directly through `--model`, the `ANTHROPIC_MODEL`
environment variable, or an `ANTHROPIC_DEFAULT_*_MODEL` environment variable…
Before v2.1.200, `--model` and the environment-variable values reached the
provider as-is."

Also worth recording, because it contradicts the schema's "typically set in
managed settings": **`modelOverrides` is read from the merged settings** —
`Co().modelOverrides` in `NZc()` — and every row above used a plain **user**
`settings.json`. Managed placement is a convention, not a requirement. The
managed source *does* become exclusive once `availableModels` is set in managed
settings (`Bce`'s `a!==void 0` branch, and DOC's paragraph on it).

### `fallbackModel` — a separate, orthogonal key

```js
function OEu(e){let t=e.cli.fallbackModel?.split(",")??(Array.isArray(e.settings.fallbackModel)?e.settings.fallbackModel:void 0);
 if(t===void 0)return;let r=new Set,n=[];
 for(let o of t){let i=typeof o==="string"?o.trim():"";if(i==="")continue;
  let s=ns(i==="default"?_0():i);…}}
```

```
fallbackModel:dt($()).optional().describe('Fallback model(s) tried in order when the primary
model is overloaded or unavailable. Each element accepts a model name or alias; "default"
expands to the default model. CLI --fallback-model takes precedence.')
```

- It is an **array** (`dt($())`), and `OEu` requires `Array.isArray` — a
  string-valued `fallbackModel` in settings is silently ignored.
- Entries go through the same `ns()` (and hence the same `Bce()` on the wire),
  so aliases and the §2 spelling rule apply identically.
- `--fallback-model` (comma-separated) beats the settings array.
- It is triggered by API error classes (`overloaded`, `model_not_found`,
  `permission_denied`, server error), not by anything the
  `ANTHROPIC_DEFAULT_*` family does.

**Unconfirmed:** I did not drive an actual overload/404 to observe a fallback
hop end-to-end — the stub returns a plain 400 with a non-Anthropic body, which
does not classify. The relationship is read off `OEu` and the error-classifier
branches only.

---

## 4. `ANTHROPIC_SMALL_FAST_MODEL`

**It has no settings-key equivalent, and `subagentModel` does not exist.**

```
$ grep -ac 'subagentModel' ~/.local/share/claude/versions/{2.1.223,2.1.224,2.1.225}
0
0
0
```

Zero occurrences in every recent version. It belongs on the same list as
`claudeCloudUrl`, `oauthClientId` and `autoUpdatesDisabled` from #13 — a
phantom key. The only model-shaped keys in the top-level settings schema are
`model`, `fallbackModel`, `availableModels`, `enforceAvailableModels` and
`modelOverrides` (BIN, enumerating `…[Mm]odel…:` schema entries).

The subagent model is env + frontmatter only:

```js
let a=te.CLAUDE_CODE_SUBAGENT_MODEL;if(a&&a!=="inherit"){let p=ns(a);if(!Ec(p))return s(a,!1);return p}
```

with precedence `CLAUDE_CODE_SUBAGENT_MODEL` → tool-supplied → agent
frontmatter → inherit (`[c,u]=l&&l!=="inherit"?[l,"env"]:r?…:[t,"inherit"]`).
That is a **different axis** from small-fast, so the ticket's suspicion was
right: they are not the same thing.

The small/fast model itself:

```js
function Epr(){if(te.ANTHROPIC_SMALL_FAST_MODEL!==void 0)return!0;
 let e=Kn(),t=e==="firstParty"&&(hf()||Kms())||fV(e);
 return te.ANTHROPIC_DEFAULT_HAIKU_MODEL!==void 0||t}
function U$(){let e=te.ANTHROPIC_SMALL_FAST_MODEL;if(e!==void 0)return FL(e);
 if(!Epr()){let t=Kn();
  if((t==="bedrock"||t==="vertex")&&pW()==null){let r=Ipu();
   if(!r.opus||r.sonnet){let n=uk();if((h3(n)??Ec(n))&&!dY(n,bV()))return n}}
  return ls()}
 return G7e()}
```

**RUN** — observed by giving the throwaway `HOME` a prompt-based
`UserPromptSubmit` hook, which runs on `U$()` (`let f=e.model??U$()`), so each
run produced two distinguishable requests:

| setup (Bedrock) | small-fast request | main request |
|---|---|---|
| `model:"opus"`, no small-fast pin | `us.anthropic.claude-opus-5` | `us.anthropic.claude-opus-5` |
| no `model` key at all | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | `us.anthropic.claude-opus-5` |
| `ANTHROPIC_SMALL_FAST_MODEL=SMALLFAST` | `SMALLFAST` | `us.anthropic.claude-opus-5` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL=HAIKUENV` | `HAIKUENV` | `us.anthropic.claude-opus-5` |
| both set | `SMALLFAST` | `us.anthropic.claude-opus-5` |

Three things follow:

1. `ANTHROPIC_SMALL_FAST_MODEL` outranks `ANTHROPIC_DEFAULT_HAIKU_MODEL`, and
   both steer background work.
2. On Bedrock/Vertex with **no** pin, the small-fast model is **Sonnet**, not
   Haiku — DOC gives the reason: "Claude Code uses the default Sonnet model for
   background tasks because Haiku may not be enabled in every account or region".
3. Pinning `model` drags background work with it (`return ls()`), so the
   `model` resource has a **cost** side-effect on third-party providers that
   its docs should mention.

DOC also records that `ANTHROPIC_SMALL_FAST_MODEL` is **deprecated in favour of
`ANTHROPIC_DEFAULT_HAIKU_MODEL`**. Both are plain `env_var` territory; neither
belongs on `auth_provider`, which keeps #13's decision to hold only
`ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION` (BIN confirms it is Bedrock-coupled:
`function iui(e,t){let r=process.env.ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION;if(e&&r&&Epr()){let n=U$()…`).

---

## 5. Side findings that touch the `model` resource

### 5a. Claude Code writes `model` into user settings itself

```js
function Ewn(e){ts("userSettings",{model:e??void 0}),ve("model_set_default")}
```

`/model` with `Enter` saves the choice to `~/.claude/settings.json`. Any
converged `model` at `:user` scope has a **live competing writer**; the drift
is a person, not a bug. `:project`, `:local` and `:enterprise` are not written
by the picker (`ura()` reports "*<source>* pins *X* — that applies on restart"
instead).

### 5b. An org default can *delete* the key — first-party only

```js
function Vwy(e,t){let r=dFt();if(!r||W7e()===null)return e;
 let n=e?Pge("model"):null;if(n==="policySettings"||n==="flagSettings")return e;
 …if(r.override_user_selection){if(a)l();return}
 if(t)return e;let c=o?tn("userSettings")?.model:void 0;
 if(s&&c){if(ts("userSettings",{model:void 0}).then(…),n==="userSettings")return}
 …}
```

`ts("userSettings",{model:void 0})` **removes the key from the file** when the
org default is newer than last seen. But:

```js
function dFt(){if(Kn()!=="firstParty")return null;return Pms()}
```

so this cannot fire under Bedrock/Vertex/Foundry/Mantle. DOC agrees the flag
form is first-party ("Admins can also configure the organization default to
override user selection… The `--model` flag, `ANTHROPIC_MODEL`, managed
settings, and `--settings` still take precedence even with override on").
Worth a docs line on `model`, but it is a **first-party** limit, the mirror
image of what the ticket expected.

### 5c. `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST` strips the keys

```js
function Xlo(e){if(delete e.model,delete e.fallbackModel,delete e.modelOverrides,e.env){…}}
```

On an embedding host, all three model keys are deleted from managed settings
before merge. Niche (web/Desktop runners), but it is a fourth way a converged
`model` can be inert.

### 5d. Provider precedence, for #13's record

```js
function Kn(){if(Eb())return"gateway";
 return te.CLAUDE_CODE_USE_BEDROCK?"bedrock":te.CLAUDE_CODE_USE_FOUNDRY?"foundry":
 te.CLAUDE_CODE_USE_ANTHROPIC_AWS?"anthropicAws":te.CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD?"anthropicGoogleCloud":
 te.CLAUDE_CODE_USE_MANTLE?"mantle":te.CLAUDE_CODE_USE_VERTEX?"vertex":"firstParty"}
```

The order is fixed and Bedrock-first — which is precisely why #13's
"apply removes all seven `CLAUDE_CODE_USE_*` keys, then sets its own" is the
only honest apply. Recorded here because this ticket had to read the function
anyway.

---

## 6. Consequences

- **#13's split holds.** `model` (section resource, settings key) and
  `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_*_MODEL` (`env_var`) address the same
  quantity at different precedence rungs, on every provider equally. Neither
  resource needs to know about the other's existence to be correct, and no
  provider makes `model` a no-op. `auth_provider` still owns provider selection
  and only `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION` of the model-ish vars.
- **`model` needs a documented scope limit, but a different one than expected**:
  the legal *values*. Its docs must say the value is an alias, a
  **catalogue-exact** Anthropic model id, or a provider-native id — and that an
  undated spelling of a dated model (`claude-sonnet-4-5`, `claude-haiku-4-5`)
  is passed through unmapped and fails at first request on Bedrock, with no
  validate-time or `check()`-time signal.
- **`modelOverrides` should be its own resource or param set, not folded into
  `model`.** It is a map keyed by Anthropic model id, it is read from merged
  settings at any scope, and it changes the meaning of *every* model selection
  including ones `model` does not make. Giving `model` a `overrides` param
  would recreate exactly the two-writers hazard #13 avoided.
- **New known limit for the README**: converging `model` on Bedrock/Vertex also
  moves background/small-fast work onto that model (`U$()` → `ls()` when a pin
  exists), which is a cost change the author did not ask for. Unpinned, those
  tasks run on Sonnet there.
- **New known limit**: at `:user` scope the `/model` picker writes the same key,
  so `model` at `:user` will report drift after any interactive model switch.
- `subagentModel` is a phantom key — remove it from #9's table (this is #18's
  surface, flagged here because #19 was asked about it directly).

---

## 7. Unconfirmed

- **Mantle** (`CLAUDE_CODE_USE_MANTLE`) and the two `ANTHROPIC_*_AWS` /
  `ANTHROPIC_GOOGLE_CLOUD` providers were not exercised end-to-end. The code
  paths (`Xhb`, `Bce`'s `Oc[n][d]` lookup) are provider-generic and the
  catalogue carries `mantle:` ids, but only bedrock/vertex/foundry were
  observed on the wire.
- **Agent frontmatter `model:`** above `ANTHROPIC_MODEL` — source line only,
  no run.
- **`fallbackModel` actually firing** — see §3; classification of the stub's
  400 was not attempted.
- The **`[1m]` suffix** interaction with third-party ids (`wS`/`pY`/`xQ` in
  `ns()`) was read but not tested; DOC says to append it to the
  `ANTHROPIC_DEFAULT_*_MODEL` value, and nothing suggests `model` differs, but
  that is inference, not evidence.
- `Xyo().state === "refused"` (a policy source that exists but fails to load)
  makes `Bce()` return the id **untranslated**, which would break a working
  `model` value on Bedrock. Read from source; not reproduced.
