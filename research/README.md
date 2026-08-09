# `claude_code` package — wayfinder research findings

Supporting detail for the research tickets of
[Design the `claude_code` package](https://github.com/Configweave/config-weave-pkgs/issues/3).

This is a **throwaway branch**. It is not intended to merge into `main` — it
exists so the design tickets can read the full findings rather than the
one-paragraph resolution comments on each issue.

| File | Ticket |
|---|---|
| `01-settings-surface.md` | [#4 settings surface and config file locations](https://github.com/Configweave/config-weave-pkgs/issues/4) |
| `02-plugins-marketplaces.md` | [#5 plugins and marketplaces](https://github.com/Configweave/config-weave-pkgs/issues/5) |
| `03-mcp.md` | [#6 MCP configuration and unattended approval](https://github.com/Configweave/config-weave-pkgs/issues/6) |
| `04-content-formats.md` | [#7 frontmatter formats](https://github.com/Configweave/config-weave-pkgs/issues/7) |
| `05-install-update.md` | [#8 install, detect and update](https://github.com/Configweave/config-weave-pkgs/issues/8) |
| `06-keybindings.md` | [#16 the keybindings.json schema](https://github.com/Configweave/config-weave-pkgs/issues/16) |
| `07-settings-key-audit.md` | [#18 audit the settings key table against the binary](https://github.com/Configweave/config-weave-pkgs/issues/18) |
| `08-model-under-providers.md` | [#19 the `model` key under third-party providers](https://github.com/Configweave/config-weave-pkgs/issues/19) |
| `09-dangerous-settings-hash.md` | [#25 can a playbook pre-consent to the dangerous-settings hash?](https://github.com/Configweave/config-weave-pkgs/issues/25) |

**Read these with care.** Every file was produced by a research subagent and
then corrected over one or two rounds against the live Claude Code install on
the authoring machine — each initial draft asserted things that turned out to
be false. The corrected versions keep their "uncertain" markers deliberately;
where a file says a thing could not be confirmed, treat that as a real gap to
close in the design ticket, not as hedging. The authoritative summary of what
was actually established is the resolution comment on each issue.

**Provenance of 06–08.** These three ran as parallel subagents. The first attempt
died on an auth failure partway; `06` and `07` therefore had a second agent
re-derive every load-bearing claim against the binary and mark where it
overturned the draft (`07`'s three headline figures reproduced exactly; both
files carry an explicit "where this overturns the earlier draft" section). `08`
lost nothing to the failure and is a **single-pass** file — it has not had the
independent correction round the other seven have, so weigh its uncertain
markers accordingly. Its central claims are the ones backed by observed runs
against a stub provider endpoint, not by code reading alone.

**`09` overturns `07`.** `07`'s closing section, "The dangerous-settings consent
hash", inferred that converging ten local settings keys would invalidate a
user's stored consent and re-prompt. `09` traced the same functions one step
further back and found the payload is built only from **remote** managed
settings fetched from Anthropic — nothing this package writes reaches it. Read
`07`'s last section as superseded; the rest of `07` stands. `09` is
**single-pass** like `08`, but every load-bearing claim is cross-checked against
2.1.223/224/226 and the hash-stability claims come from running the binary's own
functions, carved out verbatim, in Node.
