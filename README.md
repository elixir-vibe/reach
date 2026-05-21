# Reach

Program dependence graph and release-safety toolkit for Elixir, Erlang, Gleam, JavaScript, and TypeScript.

Reach builds a graph of **what depends on what** in your code: control flow, call graph, data flow, effects, and OTP/process relationships. Use it to inspect risky functions, trace values, validate architecture policy, and generate interactive HTML reports.

Elixir 1.18+ / OTP 27+.

## Installation

```elixir
def deps do
  [
    {:reach, "~> 2.0", only: [:dev, :test], runtime: false}
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

Reach separates reusable evidence from user-facing output. `Reach.Evidence.*` providers collect facts that can be consumed by smells, checks, and advisory candidates; plugin-specific evidence and smells live under `Reach.Plugins.*` and are auto-enabled only when the dependency is present. Plugins can also refine generic evidence with dependency-specific context, such as marking maps passed to `Jason.encode!/1` as external payload contracts. For provider and refinement conventions, see `docs/evidence-providers.md`. For tuning evidence providers across real projects, use `scripts/evidence_corpus_scan.exs`; see `docs/evidence-heuristics.md` for the evidence-first backlog and promotion rules.

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

HexDocs guides are organized by workflow:

- Overview, installation, and quickstart
- Canonical CLI and JSON output
- Configuration and `.reach.exs` policy
- Concepts: dependence graph, control flow, call graph, data flow, effects, OTP
- Validation and ProgramFacts oracle checks
- Recipes and contributing notes

## Validation

Reach itself is validated with:

```bash
mix compile --force --warnings-as-errors
mix ci
/tmp/reach_validate_canonical_full.sh
mix docs
mix hex.build
```

`mix ci` includes formatting, JS checks, Credo/ExSlop, ExDNA duplication checks, architecture policy, Dialyzer, and tests.

## Credo overlap

A handful of Reach smell patterns overlap with Credo refactoring checks (`MapJoin`, `FilterCount`, `FilterFilter`, `MapInto`, `UnlessWithElse`, `CondStatements`, `ExpensiveEmptyEnumCheck`). Both tools can run together — Reach findings are advisory and never fail the build.

## Acknowledgements

Some structural smell patterns were informed by public [Credence](https://github.com/Cinderella-Man/credence) rules and [Clippy](https://rust-lang.github.io/rust-clippy/) lint categories. Framework-specific smell ideas are also informed by the public [claude-elixir-phoenix](https://github.com/oliver-kriska/claude-elixir-phoenix) rule set. Reach implements them over its own IR/project model and keeps them advisory.

## License

MIT. See [`LICENSE`](LICENSE).
