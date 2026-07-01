CONFIG_WEAVE := "../config-weave/target/debug/config-weave"

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

# Regenerate the HTML docs into docs/
[group('docs')]
docs:
	{{CONFIG_WEAVE}} docs . docs

# Regenerate weave.wispi for editor/LSP support
[group('docs')]
wispi:
	{{CONFIG_WEAVE}} wispi .
