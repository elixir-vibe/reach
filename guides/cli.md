# Canonical CLI

Reach 2.x keeps the command surface intentionally small. Older task names are removed and replaced by modes on the canonical commands.

## `mix reach.map`

Project-level inventory and risk map.

```bash
mix reach.map
mix reach.map PATH
mix reach.map --modules
mix reach.map --coupling --sort instability
mix reach.map --effects
mix reach.map --boundaries --min 3
mix reach.map --depth --top 20
mix reach.map --data
```

## `mix reach.inspect TARGET`

Target-local investigation.

```bash
mix reach.inspect Module.function/arity --deps
mix reach.inspect Module.function/arity --impact
mix reach.inspect lib/file.ex:42 --context
mix reach.inspect Module.function/arity --data --variable user
mix reach.inspect Module.function/arity --why Other.Module.call/1
mix reach.inspect Module.function/arity --graph
```

## `mix reach.trace`

Data-flow and slicing workflows.

```bash
mix reach.trace --from conn.params --to Repo
mix reach.trace --from conn.params --to System.cmd --all
mix reach.trace --variable token --in MyApp.Auth.login/2
mix reach.trace lib/my_app/auth.ex:42 --forward
```

## `mix reach.check`

CI and release-safety checks.

```bash
mix reach.check --arch
mix reach.check --changed --base main
mix reach.check --dead-code
mix reach.check --smells
mix reach.check --smells --strict
mix reach.check --arch --smells --baseline .reach-baseline.json
mix reach.check --arch --smells --write-baseline .reach-baseline.json
mix reach.check --candidates
```

`--arch` is a failing gate by default. It validates layer dependency rules, optional layer coverage, source bans, call bans, boundary policy, effect policy, and layer cycles. Layer cycle output includes concrete call edges so policy failures can be traced back to source locations. `--smells` is advisory by default; add `--strict` or set `smells: [strict: true]` in `.reach.exs` to fail when non-baseline smell findings are present.

Changed-code output reports **risk** and **assessment confidence** separately. Risk is derived from the functions Reach could analyze; confidence describes how much of the diff mapped to current function definitions:

- `high` — every changed line unit was assessed;
- `partial` — some, but not all, changed line units were assessed;
- `none` — no changed line units were assessed.

A low-risk result with partial or no confidence is not a claim that the whole change is safe. Deleted-only hunks, non-source files, binary changes, and lines before the first function are reported as unassessed. For replacement hunks, Reach uses the larger of the old-side and new-side line counts as the changed line-unit count, so paired replacement lines are not double-counted. An empty diff has high confidence because there is nothing to assess.

Use `--baseline PATH` to suppress known `reach.check` findings while still failing on new findings. Use `--write-baseline PATH` to write the current findings for the selected check modes. JSON output supports one check mode at a time.

## `mix reach.otp`

OTP/process analysis.

```bash
mix reach.otp
mix reach.otp MyApp.Worker
mix reach.otp --concurrency
mix reach.otp --format json
```
