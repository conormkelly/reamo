# Contributing

REAmo v1 is in **maintenance mode**: the work here is fixing bugs and
keeping it working with new REAPER, browser and OS releases. New features
are planned for a later version, so feature PRs to v1 are unlikely to be
merged.

## Before you open a pull request

**Open an issue first and wait for a reply.** One maintainer reviews
everything, and a short discussion up front saves you writing a PR that
can't be merged. Say what's wrong, how to reproduce it, and the fix you
have in mind.

- **Bugs:** open an issue with the REAmo, REAPER, OS and browser versions
  and the steps to reproduce. Turn on **Extensions > REAmo > Debug
  Logging**, reproduce the problem, and attach `reamo.log`.
- **Security issues:** don't open an issue. Report privately as described
  in [SECURITY.md](SECURITY.md).
- **Feature ideas:** open an issue to discuss them, but expect them to wait
  for the next major version.

## Setting up

The toolchain and first run are in [DEVELOPMENT.md](DEVELOPMENT.md#quick-start):
Node, npm 11.16+, and Zig **0.15.x** exactly. Then:

```bash
make install    # dependencies, git hooks, Playwright's Chromium
make check      # lint, typecheck and every test
make            # list every target
```

## Making a change

- **Start with a failing test** that reproduces the bug, then fix it. See
  "Testing Conventions" in DEVELOPMENT.md. Anything that talks to REAPER
  needs a scenario in the
  [live-REAPER harness](scripts/harness/README.md), not just a mocked test.
- **Keep the PR to one concern.** A refactor, or an unrelated fix, goes in
  its own PR.
- **Follow the conventions** in DEVELOPMENT.md and the guides under `docs/`.
  Comments say what the code does now and why, not how it got that way.
- **Write commit messages as conventional commits**
  (`fix(timeline): keep the playhead on screen after zoom`), and use the
  body to explain why.
- **Line endings are LF** (`.gitattributes` enforces it).

## The pull request

- `make check` passes locally. CI runs the same checks.
- Link the issue it fixes and say how you tested it, including which REAPER
  version and OS.
- PRs are merged with a merge commit, so keep the branch's history tidy.
