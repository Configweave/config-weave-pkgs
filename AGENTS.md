# AGENTS.md

Instructions for agents that work on this repo in Terrarium (project
`config-weave`). Read `CLAUDE.md` and `README.md` for the package layout and
conventions. Where `CLAUDE.md` and this file disagree about the workflow (the
aciddog schedule, `.tree/` worktrees), this file wins.

## Validation recipe

One command validates a change:

```
just ci::check
```

It runs `config-weave validate .`: a WCL parse, schema check and wscript
compile of every package and the harness playbook (`.just/ci/mod.just`). It
needs the `config-weave` binary on `PATH`, at the release pinned in
`justfile` (`config_weave_version`). On the target the pinned binary lives in
`/work/config-weave/lead/.tools` (it survives a target rebuild). The full
command, the same one the merge queue runs, installs it when it is missing
(`cargo install` skips a tag that is already installed):

```
export CARGO_INSTALL_ROOT=/work/config-weave/lead/.tools PATH="/work/config-weave/lead/.tools/bin:$PATH"; just install-tool && just ci::check
```

To test both repos together, point `CONFIG_WEAVE` at a local build:
`CONFIG_WEAVE=../config-weave/target/debug/config-weave just ci::check`.

- Target: `config-weave-helios-build`. The sandbox has no compilers.
  The target does not see your workspace. Check out your pushed branch on the
  target, then run the command above in it:
  `terrarium repo checkout config-weave-pkgs --target config-weave-helios-build --branch <card-branch> --path /tmp/src/<card-id>`
  `terrarium exec config-weave-helios-build -- sh -c 'cd /tmp/src/<card-id> && <the command above>'`
  The first install of the pinned binary takes about 9 minutes: use
  `terrarium run` then. After a new push, run `repo checkout` again and check the HEAD line it
  prints. After a rebase or force push it says "the branch has diverged" and
  keeps the old commit: use a new `--path` then.
- Pushing: the ssh-agent holds two deploy keys. Pin this checkout to its own
  key, or GitHub denies the push: `ssh-add -L | grep 'github-deploy-config-weave-pkgs$' > ~/.ssh/cw-pkgs.pub`,
  then `git config core.sshCommand "ssh -o IdentitiesOnly=yes -i $HOME/.ssh/cw-pkgs.pub"`.
- There is no affected-test selector: validation always covers every package,
  and it takes seconds.
- GitHub CI runs only on pushes to `main` (`.github/workflows/release.yml`):
  `just ci::check`, then a tag and GitHub release when HEAD carries
  `pre-release: true` (vX.Y.Z-alpha) or `release: true` (vX.Y.Z).

## Convergence (required before merge)

`ci::check` does not prove that a package converges. A card that adds or
changes a resource also runs its own test declarations on the vmlab target
`config-weave-helios-vmlab` (operator decision, 2026-11-07). It has vmlab,
KVM and the static config-weave v0.11.0-alpha on `PATH` (`~/.local/bin`).
One filter per run, `package:test`:

```
terrarium repo checkout config-weave-pkgs --target config-weave-helios-vmlab --branch <card-branch> --path /home/configweave/src/<card-id>
terrarium run config-weave-helios-vmlab --name <card-id>-converge -- sh -c 'export PATH=$HOME/.local/bin:$PATH; cd $HOME/src/<card-id> && config-weave test . <package>:<test>'
```

Put each test's summary line and any failure lines in the move comment.
Never run `just test` unfiltered. Notes on the testlab:
- Every step is checked before the first apply, so a step that `requires`
  an earlier step on the same file sees the file before that step ran. The
  protocol's second apply already proves idempotence: do not add "run it
  again" steps.
- Package installs inside the micro-VMs are slow (minutes for one apt
  package): keep setups small.

## Flow (the `delivery-process` skill)

1. Claim the card from `ready` (`terrarium card claim <id> --eta <d>`).
2. Branch from `next`: `git checkout -b <card-id-lowercase> origin/next`.
   A bug card of a release branches from `release/<X.Y.Z>`.
3. Commit with conventional subjects scoped by package
   (`feat(windows_iis): ...`). Push the branch. Never push to `main`, `next`
   or a `release/*` branch.
4. Run `just ci::check` on the target against the pushed commit.
5. Green: move the card to `review` with the branch, the commit, the command,
   the exit code and the result. Red: fix it. A red you cannot fix goes to
   `blocked` with the output tail.
6. The lead reviews and moves the card to `merge_queue`. The merge job merges
   the whole column onto `next`, runs `just ci::check` on the result, and moves
   green cards to `accepted`.
