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
  `terrarium run` then. After a new push, run `repo checkout` again.
- Pushing: the ssh-agent holds two deploy keys. Pin this checkout to its own
  key, or GitHub denies the push: `ssh-add -L | grep 'github-deploy-config-weave-pkgs$' > ~/.ssh/cw-pkgs.pub`,
  then `git config core.sshCommand "ssh -o IdentitiesOnly=yes -i $HOME/.ssh/cw-pkgs.pub"`.
- There is no affected-test selector: validation always covers every package,
  and it takes seconds.
- `ci::check` does not prove that a package converges. When a card changes a
  package's behaviour, also run its convergence tests with a filter, for
  example `just test linux_files` or `just test mssql:config_converges`, when
  the target has vmlab and KVM. Put the result in the move comment, or say
  that the target could not run it. Never run `just test` unfiltered.
- This repo has no GitHub CI.

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
