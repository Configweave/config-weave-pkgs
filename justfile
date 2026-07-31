# The config-weave binary. Defaults to a PATH lookup (`just install-tool`
# installs it from GitHub) rather than a sibling build tree, because a ticket
# worktree lives at <repo>/.tree/<ticket> where a relative `../` path resolves
# to nothing. Point it at a local build to develop the two together:
#   CONFIG_WEAVE=../config-weave/target/debug/config-weave just check
export CONFIG_WEAVE := env("CONFIG_WEAVE", "config-weave")

# Fixed dev-server address so the pkg docs never collide with config-weave's
# own docs site (8280) or other projects on the default 8080. Must match
# pkgs_docs_addr in the config-weave repo.
DOCS_ADDR := "127.0.0.1:8281"

[default, private]
main:
	@just --list

# The merge bar — everything a change must pass before it can merge
mod ci '.just/ci'

# Install the config-weave binary this repo checks against, from GitHub.
[group('check'), doc("Install the config-weave binary from GitHub into ~/.cargo/bin")]
install-tool:
	cargo install --git https://github.com/Configweave/config-weave.git --locked

# Validate every package and the harness playbook
[group('check')]
validate: ci::validate

# The whole merge bar (`ci::check`), under the name the config-weave repo uses
[group('check')]
check: ci::check

# Unfiltered runs everything — container tests, VM tests and scenarios (needs
# vmlab, KVM, and the templates the VM tests name). Scope with a filter, e.g.
# `just test linux_files` or `just test mssql:config_converges`. Not part of
# the merge bar: see the note on `ci::check`.

# Run the testlab (filterable; needs vmlab and KVM)
[group('test')]
test filter='':
	{{CONFIG_WEAVE}} test . {{filter}}

# Regenerate the HTML docs into docs/ (packages only — the harness
# playbook's play/vars/gathers are not part of the public surface).
# Clean first: the renderer never deletes, so removed pages linger.
[group('docs')]
docs:
	rm -rf docs
	{{CONFIG_WEAVE}} docs . docs --pkg-only

# Regenerate weave.wscripti (and wscript.toml) for editor/LSP support
[group('docs')]
wscripti:
	{{CONFIG_WEAVE}} wscripti .

# Rebuild the package docs and serve them with WCL's watch-rebuild dev
# server (live reload). Needs `wcl` on PATH.
[group('docs'), doc("Rebuild + serve the package docs with live reload (needs wcl)")]
docs-serve:
	rm -rf docs
	{{CONFIG_WEAVE}} docs . docs --pkg-only --serve --addr {{DOCS_ADDR}}

# Serve the package docs and open them in the browser once the server responds
[group('docs')]
docs-open: (browser-open "http://" + DOCS_ADDR + "/") docs-serve

# Wait for `url` to respond, then open it in the default browser. Backgrounds
# itself so a blocking server recipe can run as the next dependency.
[private]
browser-open url:
	@( for _ in $(seq 1 60); do curl -sf -o /dev/null '{{url}}' && break; sleep 0.5; done; xdg-open '{{url}}' ) >/dev/null 2>&1 &
