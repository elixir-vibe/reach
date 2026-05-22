# Reach — Agent Guidelines

This repository is part of the Elixir Vibe organization.

## Architecture

Reach builds a Program Dependence Graph from Elixir/Erlang source code and visualizes it as interactive HTML reports with three views: Control Flow, Call Graph, Data Flow.

Key modules:
- `Reach.Frontend.Elixir` — AST → IR translation
- `Reach.ControlFlow` — IR → CFG (per-function DAG, never cyclic)
- `Reach.Dominator` — immediate dominator/post-dominator, dominator tree, dominance frontier
- `Reach.Effects` — per-call side-effect classification (pure/io/read/write/send/exception/nif/unknown)
- `Reach.DependencySummary` — compiled dependency parameter-to-return summaries
- `Reach.Visualize.ControlFlow` — CFG → visualization blocks/edges
- `Reach.Visualize.Source` — source extraction, highlighting, line helpers
- `Reach.Visualize.Helpers` — IR label and pattern rendering helpers
- `assets/js/components/ReachGraph.vue` — frontend (Vue Flow + ELK layout)

## CLI Architecture Rules

Reach 2.x has five canonical dotted Mix tasks:

| Command | Purpose |
|---|---|
| `mix reach.map` | Project map: summary, modules, coupling, effects, hotspots, depth, data/xref |
| `mix reach.inspect TARGET` | Target-local deps, impact, graph, context, why, data, candidates |
| `mix reach.trace` | Data flow, taint paths, backward/forward slices |
| `mix reach.check` | CI/release checks: architecture, changed-code risk, dead code, smells, candidates |
| `mix reach.otp` | OTP/process analysis: behaviours, supervision, concurrency, coupling |

Removed commands must stay hard-deprecated shims only. They must raise exact migration guidance and must never delegate:

| Removed | Use instead |
|---|---|
| `mix reach.modules` | `mix reach.map --modules` |
| `mix reach.coupling` | `mix reach.map --coupling` |
| `mix reach.hotspots` | `mix reach.map --hotspots` |
| `mix reach.depth` | `mix reach.map --depth` |
| `mix reach.effects` | `mix reach.map --effects` |
| `mix reach.boundaries` | `mix reach.map --boundaries` |
| `mix reach.xref` | `mix reach.map --data` |
| `mix reach.deps TARGET` | `mix reach.inspect TARGET --deps` |
| `mix reach.impact TARGET` | `mix reach.inspect TARGET --impact` |
| `mix reach.slice TARGET` | `mix reach.trace TARGET` |
| `mix reach.flow ...` | `mix reach.trace ...` |
| `mix reach.dead_code` | `mix reach.check --dead-code` |
| `mix reach.smell` | `mix reach.check --smells` |
| `mix reach.graph TARGET` | `mix reach.inspect TARGET --graph` |
| `mix reach.concurrency` | `mix reach.otp --concurrency` |

### Non-negotiable CLI constraints

- Never call Reach Mix tasks internally:
  - no `TaskRunner.run(...)`
  - no `Mix.Tasks.Reach.*.run(...)`
  - no `Mix.Task.run("reach...")`
- Do not reintroduce `Reach.CLI.TaskRunner`, `Deprecation.delegated/1`, or command override tunnels.
- Mix tasks parse args once and pass parsed options/positional args forward; do not rebuild argv strings with `maybe_put/3` / `maybe_flag/3` helpers.
- Compile handling belongs in `Reach.CLI.Project`; do not scatter `Mix.Task.run("compile", ...)` across commands.
- JSON output must use canonical command envelopes (`reach.map`, `reach.inspect`, `reach.trace`, `reach.check`, `reach.otp`) and remain pure JSON with no preamble.
- Broken-pipe handling belongs at CLI entrypoints via `Reach.CLI.Pipe`.

## Target Subsystem Boundaries

Use this responsibility split when refactoring or adding features:

| Layer | Owns | Must not own |
|---|---|---|
| `Mix.Tasks.Reach.*` | CLI entrypoint, option parsing, invoking canonical command layer | analysis, rendering details, internal task calls |
| `Reach.CLI.Commands.*` | canonical command orchestration and mode selection | graph algorithms, smell rules, taint semantics |
| `Reach.CLI.Render.*` / `Reach.CLI.Format` | text/JSON rendering, colors, truncation, human labels | domain decisions |
| `Reach.CLI.Project`, `Reach.CLI.Options`, `Reach.CLI.Pipe` | shared CLI infrastructure | domain analysis |
| `Reach.Check.*` | CI/release policy checks and check adapters | local smell rule implementations |
| `Reach.Smell.*` | structural/code-shape smell engine and smell findings | CLI rendering |
| `Reach.Trace.*` | taint/data-flow/slicing domain logic and trace patterns | CLI rendering or hardcoded CLI-only presets |
| `Reach.Inspect.*` | target-local deps/impact/context/why/candidate analysis | CLI rendering |
| `Reach.OTP.*` | OTP/process/domain analysis | CLI rendering |
| `Reach.Visualize.*` | graph/HTML/web visualization | CLI command orchestration |
| `Reach.Plugin` / `Reach.Plugins.*` | framework-specific semantics: effect classification, trace presets, behaviour labels, visualization edge filtering, framework graph edges | generic smell/trace/map/visualization policy |

`Reach.CLI.Analyses.*` must not exist; add command orchestration under `Reach.CLI.Commands.*` and domain logic under the appropriate `Reach.*` subsystem.

Framework-specific semantics must stay in plugins. Generic modules such as `Reach.Smell.*`, `Reach.Evidence.*`, `Reach.Trace.*`, `Reach.Map.*`, and `Reach.Visualize` must not hardcode framework/library names such as Ecto/Repo/Phoenix/Oban/Ash/Jido or framework-specific CRUD/validation calls. Add plugin callbacks instead.

## Constants and Limits

- No unexplained magic numbers like `Enum.take(20)` or `Enum.take(30)` in domain code.
- Analysis safety caps must be named options/defaults, e.g. `max_return_dependents`, `max_dependency_nodes`.
- Text display limits belong in CLI command/render defaults and should be user-overridable where practical.
- Hardcoded framework taint examples such as `conn.params` and `Repo.query` belong in plugin trace pattern callbacks, not generic trace/CLI modules. Generic built-in patterns may cover platform/runtime calls such as `System.cmd`.

## Check vs Smell

- `Reach.Check.*` is for release/CI safety: architecture policy, changed-code risk, refactoring candidates, and adapters that run checks.
- `Reach.Smell.*` is the local code-shape finding engine: loose map contracts, repeated fixed-shape maps, pipeline waste, reverse append, eager patterns, string building, redundant computation, and clone-backed structural consistency.
- `mix reach.check --smells` may call the smell engine, but smell rules themselves must live under `Reach.Smell.*`, not `Reach.CLI.*`.
- `Reach.Evidence.*` contains reusable evidence providers consumed by smells, checks, and refactoring candidates. Evidence is an observed fact; smells/checks/candidates are user-facing policy decisions. Evidence modules must not emit user-facing findings directly. ExDNA integration must emit Reach-owned clone evidence consumed by semantic checks; ExDNA must not appear as a user-facing smell kind. See `docs/evidence-heuristics.md` for the evidence-first promotion path.

## Release and Docs

- Keep `ex_doc` available in the `:docs` Mix environment (`only: [:dev, :docs]`).
- `mix docs` and `mix hex.publish docs` must run in the `:docs` Mix environment via `cli.preferred_envs`.
- Reason: dev-only `volt` may depend on `reach`; building docs in dev can load Hex `reach` alongside this repo and fail with a duplicate `Reach.MixProject` self-dependency.

## Tests and Refactors

Before reorganizing tests, preserve the full inventory:

```bash
mix test --trace > /tmp/reach-test-inventory-before.txt
rg 'test "|property "|describe "' test test_helpers > /tmp/reach-test-declarations-before.txt
```

Move tests with `git mv` first, keep test names unchanged, then split/refactor. Afterward:

```bash
mix test --trace > /tmp/reach-test-inventory-after.txt
rg 'test "|property "|describe "' test test_helpers > /tmp/reach-test-declarations-after.txt
```

No existing test name may disappear unless it is intentionally replaced by an equivalent test noted in the commit message.

Add/maintain architecture regression tests for:
- no forbidden source modules/files such as `Reach.CLI.Analyses.*` and `Reach.CLI.TaskRunner`
- no internal Reach Mix task calls
- removed tasks only raise migration guidance
- no domain module calls CLI rendering/project helpers unless explicitly transitional
- no direct compile calls outside `Reach.CLI.Project`
- no magic `Enum.take(N)` in domain modules without named limits
- no hardcoded trace source/sink presets in CLI modules
- no framework-specific policy in generic smell, clone-analysis, trace, map, or visualization modules; put it behind `Reach.Plugin` callbacks

## Block Quality Acceptance Criteria

Every change to visualization code MUST maintain these invariants, tested across real codebases (Elixir, Phoenix, Ecto, Oban, Plausible, Livebook — 16k+ functions).

### Coverage
1. Every source line of the function body appears in exactly one block. Entry = def line, exit = end line. Allow ≤5 missing lines per function (compiler limitation with pipe chains and heredocs).

### Disjointness
2. No two blocks share the same source line range. Block end_line is clamped to `min(raw_end, min_next_start - 1)` across ALL blocks, not just the next one in traversal order. Block end_line uses `Enum.max` across all vertex end_lines in the block (earlier vertices can have wider ranges than the last one).

### Branch Boundaries
3. Every branch point (case/if/cond/receive/try/with) creates a new block.
4. Every clause is its own block.
5. Anonymous fn bodies are decomposed — `Enum.reduce(fn ... end)` callbacks with internal branching get split into blocks. Multi-clause `fn` dispatches like `case`.

### Block Content
6. No empty blocks — every block has `source_html`. Clauses with no compiler source spans show the pattern label as fallback.
7. No nil labels — every block has a meaningful label.

### Structural
8. Entry block = function signature. Exit block = function end. Exit must be connected via edges (use `find_exit_predecessors`).
9. Sequential chains on distinct lines merge into one block.
10. Same-line nested constructs stay separate — merge only when there's a single branch winner on the line.

### Edge Correctness
11. Every edge maps to a real CFG path.
12. Multi-clause functions show dispatch → clause edges with pattern labels.

### No Duplicate Lines
13. No source line appears in more than one block (except def/end lines shared by entry/exit).

## Multi-clause Functions

Multi-clause functions with bodies use `build_multi_clause_cfg` — the CFG includes clause nodes as vertices (normally filtered out), dispatch edges from entry to each clause block, and full CFG decomposition inside each clause body. Pure pattern dispatches (all clauses ≤2 children) go through the normal single-function CFG path.

## Testing Changes

Run the block quality test after visualization changes:

```bash
mix test test/reach/visualize/block_quality_test.exs
```

Smoke test across real codebases — clone first if needed:

```bash
for repo in elixir-lang/elixir phoenixframework/phoenix elixir-ecto/ecto oban-bg/oban; do
  name=$(basename $repo)
  [ -d /tmp/$name ] || git clone --depth 1 https://github.com/$repo /tmp/$name
done
```

```elixir
dirs = ["/tmp/phoenix/lib", "/tmp/ecto/lib", "/tmp/oban/lib", "/tmp/elixir/lib"]
# Check: zero crashes on to_json, verify block quality metrics
```

## What NOT to Do

- Don't use string matching to extract source constructs (use the parsed AST/IR)
- Don't merge same-line blocks when multiple branch vertices share the line
- Don't take block end_line from only the last vertex — use max across all
- Don't filter out clause nodes from the CFG for multi-clause functions
- Don't create exit nodes without connecting them via edges
