CONFIG_WEAVE := "../config-weave/target/debug/config-weave"

validate:
    {{CONFIG_WEAVE}} validate .

test:
    {{CONFIG_WEAVE}} test .

docs:
    {{CONFIG_WEAVE}} docs . docs

check: validate

wispi:
    {{CONFIG_WEAVE}} wispi .

