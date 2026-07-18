CONFIG_WEAVE := "../config-weave/target/debug/config-weave"

# Fixed dev-server address so the pkg docs never collide with config-weave's
# own docs site (8280) or other projects on the default 8080. Must match
# pkgs_docs_addr in ../config-weave.
DOCS_ADDR := "127.0.0.1:8281"

[default, private]
main:
	@just --list

# Validate every package and the harness playbook
[group('check')]
validate:
	{{CONFIG_WEAVE}} validate .

# Alias for validate, matching the config-weave repo
[group('check')]
check: validate

# Run the testlab. Unfiltered runs everything — docker tests, vmlab tests and
# scenarios (needs docker AND vmlab). Scope with a filter, e.g.
# `just test linux_files` or `just test mssql:config_converges`.
[group('test')]
test filter='':
	{{CONFIG_WEAVE}} test . {{filter}}

# Regenerate the HTML docs into docs/ (packages only — the harness
# playbook's play/vars/gathers are not part of the public surface)
[group('docs')]
docs:
	{{CONFIG_WEAVE}} docs . docs --pkg-only

# Regenerate weave.wispi for editor/LSP support
[group('docs')]
wispi:
	{{CONFIG_WEAVE}} wispi .

# Rebuild the package docs and serve them with WCL's watch-rebuild dev
# server (live reload). Needs `wcl` on PATH.
[group('docs'), doc("Rebuild + serve the package docs with live reload (needs wcl)")]
docs-serve:
	{{CONFIG_WEAVE}} docs . docs --pkg-only --serve --addr {{DOCS_ADDR}}

# Serve the package docs and open them in the browser once the server responds
[group('docs')]
docs-open: (browser-open "http://" + DOCS_ADDR + "/") docs-serve

# Wait for `url` to respond, then open it in the default browser. Backgrounds
# itself so a blocking server recipe can run as the next dependency.
[private]
browser-open url:
	@( for _ in $(seq 1 60); do curl -sf -o /dev/null '{{url}}' && break; sleep 0.5; done; xdg-open '{{url}}' ) >/dev/null 2>&1 &
