# Working on Denial (the NX809J fork)

This is the owner's own project, grown out of upstream Denial (denialwm). It no
longer follows upstream: change anything, core parts included, when it makes
the phone better. Pulling an upstream commit in is fine when it helps; never
propose changes upstream.

The project's rules, git identity, what needs asking and how to report are in
`/home/user/nx809j_linux/AGENTS.md`; read it first. This file only adds what is
specific to this repo.

[README.md](README.md) and [docs/architecture.md](docs/architecture.md)
explain the compositor; [docs/BUILDING.md](docs/BUILDING.md) is upstream's build
reference (its hosts, CI and release steps don't apply here). For plugin work
read [docs/PLUGIN_DEVELOPMENT.md](docs/PLUGIN_DEVELOPMENT.md).

## Repository
- Work branch `nx809j-20261103` tracks `reixo/main`; pushing (with the
  owner's go-ahead) is `git push reixo HEAD:main`. No `dev` branch, CI
  builder, promotion or release tags.
- Commit only the files of the work the owner asked to commit.
- Shells are zsh: quote globs and never rely on word splitting.

## Building and deploying
- `/home/user/nx809j_linux/scripts/build-denial.sh` builds the host and phone
  Flutter engines (cache in `~/.cache/denial`), the compositor, the shell and
  the apps. Deploy steps are in the notes (`workflows.md`).
- Restarting `nx809j-denial` on the phone for a deploy needs no asking; say so.
  Then confirm a new `deniald` runs.
- Never overwrite an engine a running process maps (truncating it can crash the
  live compositor). Keep the previous build when installing a new one.
- Never run `flutter test` directly for `dart_shell`.

## Failed deploys
A build that fails to start or work on the phone is a result to report, not to
undo: don't roll back on your own. Say what is installed, what is running and
where the previous version is, and ask.

## Visual checks
- The owner judges every visual result: whether it looks right is never the
  agent's call.
- Screenshots, screen recordings and off-phone renders are fine as
  measurement (positions, sizes, timings, colours), for example to compare
  with the owner's Android recordings. Report the numbers; don't declare it
  matches.
- Never trigger a notification or other visible event on the phone unless the
  owner asks for that one.
