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

The project summary includes source-suppression totals and the number lacking justification reasons, making suppression growth visible even outside changed-code checks.

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
mix reach.trace --pattern regex-on-structured
mix reach.trace --variable token --in MyApp.Auth.login/2
mix reach.trace lib/my_app/auth.ex:42 --forward
```

`regex-on-structured` traces structured file contents into regex APIs, regex `=~`, and regex-based `String.split/2`. It uses static structured file extensions when available and a conservative structure-shaped regex fallback for dynamic paths.

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

`decoded_boundary_leakage` reports plugin-owned decoded data stored or sent without explicit normalization when fixed literal-key consumers show that the payload behaves as an implicit contract. Normalize at the reported storage/process boundary rather than adding defensive defaults downstream. `--candidates` turns the same evidence into an `introduce_boundary_contract` proposal with a draft contract, proof checklist, and graph-backed blast radius.

`return_shape_divergence` reports incompatible success contracts only when backed by a closed `@spec` mismatch, an unwrapped raw error beside tagged errors, or a tagged nil/empty edge case beside raw successful values. Optional success payloads, parser/callback tuple arities, explicit or open unions remain evidence-only. Nested same-tag results also remain evidence because their outer and inner tuples often belong to independent protocol layers. Messages include every promoted terminal shape and source line.

`nil_parameter_without_guard` reports a parameter proven nil-capable by a call, default, or matching clause when a strict use has no dominating non-nil proof. It accounts for clause order, companion arguments, `if`/`unless`/`cond`/`case` paths, `with` and body rebinding, comprehensions, default wrappers, and private recursive helpers before promotion. The finding identifies both the nil source and unsafe use; fix the contract with a clause-head guard or normalize before every reported path rather than rescuing the eventual crash.

`same_entity_representation` reports cross-module bare maps whose keys and entity-bearing names closely match an existing struct. Source patterns, explicit struct values, nested projections, adapter/presentation maps, accumulators, and maps normalized directly or by consistently struct-building callers are excluded. Findings name the canonical struct and every retained bare-map location.

`parameter_shape_entropy` reports domain parameters that strictly consume varying keys while receiving divergent fixed map shapes from distinct callers. Options/payload roles, defensive optional fields, function-head map patterns, companion-selected shapes, tagged unions, and explicit or guarded dispatch are excluded. `--changed` separately reports qualifying entropy increases with old/new values and raises aggregate risk to medium.

Changed-code output reports **risk** and **assessment confidence** separately. Risk is derived from the functions Reach could analyze plus high-confidence contract-erosion events; confidence describes how much of the diff mapped to current function definitions:

- `high` — every changed line unit was assessed;
- `partial` — some, but not all, changed line units were assessed;
- `none` — no changed line units were assessed.

A low-risk result with partial or no confidence is not a claim that the whole change is safe. Deleted-only hunks, non-source files, binary changes, and lines before the first function are reported as unassessed. For replacement hunks, Reach uses the larger of the old-side and new-side line counts as the changed line-unit count, so paired replacement lines are not double-counted. An empty diff has high confidence because there is nothing to assess.

Changed analysis also compares old and new ASTs inside each hunk. Replacing required field access, `Map.fetch!/2`, or a required map pattern with `Map.get/2,3` appears under **Access strictness downgrades** and raises aggregate change risk to at least medium. When the current call graph contains map-literal callers missing the key, Reach names those producers so they can be normalized instead of weakening the consumer.

**Displaced evidence** means a stable dual-key contract, conflicting-default set, or exact whole-function clone disappeared from its old changed location but reappeared at a new changed location with the same or a greater occurrence count. Reach reports it as displaced rather than resolved and raises aggregate risk to at least medium.

New source suppressions are listed as added, removed, or unchanged. Added suppressions should use `# reach:disable KIND -- REASON` (or the existing `disable-next-line` / `disable-for-this-file` forms). A reasonless addition raises aggregate changed-code risk to at least medium; a justified addition remains visible without changing risk. `mix reach.map` includes total and reasonless source-suppression counts.

Use `--baseline PATH` to suppress known `reach.check` findings while still failing on new findings. Use `--write-baseline PATH` to write the current findings for the selected check modes. JSON output supports one check mode at a time.

## `mix reach.otp`

OTP/process analysis.

```bash
mix reach.otp
mix reach.otp MyApp.Worker
mix reach.otp --concurrency
mix reach.otp --format json
```
