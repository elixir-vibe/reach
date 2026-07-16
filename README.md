# Reach

Program dependence graph and release-safety toolkit for Elixir, Erlang, Gleam, JavaScript, and TypeScript.

Reach builds a graph of **what depends on what** in your code: control flow, call graph, data flow, effects, and OTP/process relationships. Use it to inspect risky functions, trace values, validate architecture policy, and generate interactive HTML reports.

Use Reach when you want to answer questions like:

- What depends on this function before I change it?
- Can user input reach a database, shell command, file write, or external boundary?
- Did this PR cross an architecture boundary?
- Which modules are coupled, effect-heavy, or likely hotspots?
- Which OTP processes, callbacks, and handlers interact?
- Are there review leads worth checking before a release?

Reach is designed to surface review leads, not replace judgment. Smell findings are advisory by default; use strict checks when you want them to gate CI.

Elixir 1.18+ / OTP 27+.

## Installation

```elixir
def deps do
  [
    {:reach, "~> 2.6", only: [:dev, :test], runtime: false}
  ]
end
```

Optional dependencies enable richer output:

```elixir
{:jason, "~> 1.0"},       # JSON output
{:boxart, "~> 0.3.3"},    # terminal graphs
{:makeup, "~> 1.0"},
{:makeup_elixir, "~> 1.0"},
{:makeup_js, "~> 0.1"}
```

## Quickstart

Start with the HTML report, then run one focused check:

```bash
mix reach
mix reach.check --smells
mix reach.inspect MyApp.Accounts.create_user/1 --context
```

- `mix reach` writes an interactive report for exploring control flow, calls, and data flow.
- `mix reach.check --smells` prints advisory review leads.
- `mix reach.inspect ... --context` shows the local dependency context around a target.

Generate an interactive report:

```bash
mix reach
```

Map the project:

```bash
mix reach.map
mix reach.map --modules
mix reach.map --coupling
mix reach.map --hotspots
```

Inspect a target:

```bash
mix reach.inspect MyApp.Accounts.create_user/1 --context
mix reach.inspect lib/my_app/accounts.ex:42 --impact
mix reach.inspect MyApp.Accounts.create_user/1 --why MyApp.Repo
```

Trace data:

```bash
mix reach.trace --from conn.params --to Repo
mix reach.trace --pattern regex-on-structured
mix reach.trace --variable changeset --in MyApp.Accounts.create_user/1
```

Run release checks:

```bash
mix reach.check --arch
mix reach.check --changed --base main
mix reach.check --smells --strict
mix reach.check --arch --smells --write-baseline .reach-baseline.json
mix reach.check --candidates
```

Inspect OTP/process risks:

```bash
mix reach.otp
mix reach.otp --concurrency
```

## Common workflows

| I want to… | Run |
|---|---|
| Open an interactive HTML report | `mix reach` |
| See modules, coupling, effects, hotspots, and depth | `mix reach.map` |
| Review module coupling | `mix reach.map --coupling` |
| Inspect what a function depends on | `mix reach.inspect MyApp.Accounts.create_user/1 --deps` |
| Estimate impact before changing a function or line | `mix reach.inspect MyApp.Accounts.create_user/1 --impact` |
| Understand why a target reaches another target | `mix reach.inspect MyApp.Accounts.create_user/1 --why MyApp.Repo` |
| Trace data from a source to a sink | `mix reach.trace --from conn.params --to Repo` |
| Run architecture policy checks | `mix reach.check --arch` |
| Run advisory smell checks | `mix reach.check --smells` |
| Gate CI on architecture and smells | `mix reach.check --arch --smells --strict` |
| Inspect OTP/process relationships | `mix reach.otp --concurrency` |

## Canonical CLI

Reach 2.x uses five canonical analysis tasks plus the HTML report task.

| Command | Purpose |
|---|---|
| `mix reach` | Interactive HTML report |
| `mix reach.map` | Project map: modules, coupling, hotspots, effects, depth, data flow |
| `mix reach.inspect TARGET` | Target-local deps, impact, graph, context, data, candidates, why paths |
| `mix reach.trace` | Data-flow, taint, and slicing workflows |
| `mix reach.check` | CI/release checks: architecture, changed code, dead code, smells, candidates |
| `mix reach.otp` | OTP/process analysis: behaviours, state machines, supervision, concurrency, coupling |

Use `--format json` for automation. Canonical commands emit pure JSON envelopes with stable command names.

Reach automatically enables extra semantics when it sees dependencies such as Phoenix, LiveView, Ecto, Oban, Jason, ExUnit, and related ecosystem libraries.

Internally, Reach separates reusable evidence from user-facing output. `Reach.Evidence.*` providers collect facts that can be consumed by smells, checks, and advisory candidates; plugin-specific evidence and smells live under `Reach.Plugins.*` and are auto-enabled only when the dependency is present. Plugins can also refine generic evidence with dependency-specific context, such as marking maps passed to `Jason.encode!/1` as external payload contracts. For provider and refinement conventions, see `docs/evidence-providers.md`. For tuning evidence providers across real projects, use `scripts/evidence_corpus_scan.exs`; see `docs/evidence-heuristics.md` for the evidence-first backlog and promotion rules.

Older task names were removed in Reach 2.0 and fail fast with migration guidance. See the [Canonical CLI guide](guides/cli.md).

## Configuration

Reach reads `.reach.exs` for architecture and change-safety policy:

```elixir
[
  layers: [
    web: "MyAppWeb.*",
    domain: "MyApp.*",
    data: ["MyApp.Repo", "MyApp.Schemas.*"]
  ],
  deps: [
    forbidden: [
      {:domain, :web},
      {:data, :web}
    ]
  ],
  source: [
    forbidden_modules: ["MyApp.Legacy.*"],
    forbidden_files: ["lib/my_app/legacy/**"]
  ],
  calls: [
    forbidden: [
      {"MyApp.Domain.*", ["IO.puts", "Jason.encode!"]}
    ]
  ],
  tests: [
    hints: [
      {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]}
    ]
  ]
]
```

Then run:

```bash
mix reach.check --arch
```

Reach reports forbidden layer, source, and call violations from the policy.

Start from [`examples/reach.exs`](examples/reach.exs). See the [configuration guide](guides/configuration.md) for the full reference and narrative examples.

## Library API

Reach can also analyze snippets, files, and source directories directly:

```elixir
graph = Reach.string_to_graph!("""
def run(input) do
  command = String.trim(input)
  System.cmd("sh", ["-c", command])
end
""")

[cmd_call] = Reach.nodes(graph, type: :call, module: System, function: :cmd)
Reach.backward_slice(graph, cmd_call.id)
```

Common queries:

```elixir
Reach.backward_slice(graph, node_id)
Reach.forward_slice(graph, node_id)
Reach.taint_analysis(graph, sources: [function: :params], sinks: [module: System, function: :cmd])
Reach.independent?(graph, node_a.id, node_b.id)
Reach.data_flows?(graph, source_id, sink_id)
```

## Documentation

Read the full docs at [hexdocs.pm/reach](https://hexdocs.pm/reach).

HexDocs guides are organized by workflow:

- Overview, installation, and quickstart
- Canonical CLI and JSON output
- Configuration and `.reach.exs` policy
- Concepts: dependence graph, control flow, call graph, data flow, effects, OTP
- Validation and ProgramFacts oracle checks
- Recipes and contributing notes

For repository workflow and smell-rule validation expectations, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Contributing

Reach welcomes bug reports, feature ideas, and new smell-rule proposals. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the local workflow, architecture expectations, and corpus-validation process.

When proposing a new smell rule, please include examples of code that should be flagged and nearby code that should not be flagged. New or broadened smell rules need a false-positive scan against real code before they can be merged; if you are not ready to run that scan, open a “New smell rule” issue and maintainers can evaluate it.

Useful issue templates are available for:

- bug reports
- feature requests
- new smell rules

## Validation

Reach itself is validated with:

```bash
mix compile --force --warnings-as-errors
mix ci
mix docs
mix hex.build
```

`mix ci` includes formatting, JS checks, Credo/ExSlop, ExDNA duplication checks, architecture policy, Dialyzer, and tests.

## Credo overlap

A handful of Reach smell patterns overlap with Credo refactoring checks (`MapJoin`, `FilterCount`, `FilterFilter`, `MapInto`, `UnlessWithElse`, `CondStatements`, `ExpensiveEmptyEnumCheck`). Both tools can run together. Reach findings are advisory by default; they only fail a build when you opt into strict/CI checks such as `mix reach.check --smells --strict` or project policy does so.

## Acknowledgements

Some structural smell patterns were informed by public [Credence](https://github.com/Cinderella-Man/credence) rules and [Clippy](https://rust-lang.github.io/rust-clippy/) lint categories. Framework-specific smell ideas are also informed by the public [claude-elixir-phoenix](https://github.com/oliver-kriska/claude-elixir-phoenix) rule set. Reach implements them over its own IR/project model and keeps them advisory.

## Part of Elixir Vibe

Reach answers "what depends on this, and can you prove it?" — dependence graphs, slicing, effects, and architecture checks for BEAM projects.

It is one building block of a larger stack — tools that make AI-generated
software checkable: structural search, dependence analysis, duplication and
slop detection, session replay, and ecosystem-wide code search. See the
[Elixir Vibe](https://github.com/elixir-vibe) organization for the rest, and
[Building Blocks for the Future Web](https://github.com/elixir-vibe/building-blocks)
for the thesis, architecture, and roadmap that tie them together.

## License

MIT. See [`LICENSE`](LICENSE).
