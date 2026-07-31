# The merge bar: everything a change must pass before it can land on main.

import '../shared.just'

# Recipes here operate on the repository, not on .just/ci/, which is where a
# module's recipes would otherwise run.
set working-directory := '../..'

[default, private]
main:
	@just --list ci

# `just test` is deliberately outside the gate: it boots real vmlab VMs to
# converge packages, which is KVM-bound, slow, and worth watching rather than
# retrying blind. Convergence stays a human action.

# Everything a change must pass to merge — excludes the VM tests, so passing it is no proof a package converges
[group('ci')]
check: validate

# Parse, schema-check and compile every package and the harness playbook
[group('ci')]
validate: require-config-weave
	"$CONFIG_WEAVE" validate .
