# Helpers shared by every module under .just/, merged into the importing
# module's namespace.

# Fail legibly when config-weave is missing, so a failed gate reads as "this
# machine can't run the check" rather than as a broken package.
#
# Reads $CONFIG_WEAVE — the environment variable the top-level justfile
# exports, which always has a value — rather than a module-level `env()`.
# A module's variables are evaluated in just's own process, which the export
# never reaches, so `env()` here would quietly ignore `just --set CONFIG_WEAVE`
# and guard a different binary from the one the recipe runs.
[private]
require-config-weave:
	@command -v "$CONFIG_WEAVE" >/dev/null 2>&1 || { echo "config-weave not found ($CONFIG_WEAVE). Run 'just install-tool', or point CONFIG_WEAVE at a local build." >&2; exit 1; }
