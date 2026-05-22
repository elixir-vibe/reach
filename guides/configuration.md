# Configuration

Reach reads architecture, change-safety, advisory candidate, and smell policy from `.reach.exs`.

```bash
mix reach.check --arch
mix reach.check --changed
mix reach.check --candidates
mix reach.check --smells
mix reach.inspect TARGET --candidates
```

The file must evaluate to a keyword list. Start from [`examples/reach.exs`](../examples/reach.exs), then tune it to your project.

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
      {"MyApp.Domain.*", ["IO.puts", "Jason.encode!"]},
      {"MyApp.Workers.*", ["System.cmd"], except: ["MyApp.Workers.Cleanup"]}
    ]
  ],
  effects: [
    allowed: [
      {"MyApp.Pure.*", [:pure, :unknown]}
    ]
  ],
  boundaries: [
    public: ["MyApp.Accounts"],
    internal: ["MyApp.Accounts.Internal.*"],
    internal_callers: [
      {"MyApp.Accounts.Internal.*", ["MyApp.Accounts", "MyApp.Accounts.*"]}
    ]
  ],
  risk: [
    changed: [
      many_direct_callers: 5,
      wide_transitive_callers: 10,
      branch_heavy: 8,
      high_risk_reason_count: 3
    ]
  ],
  candidates: [
    thresholds: [
      mixed_effect_count: 2,
      branchy_function_branches: 8,
      high_risk_direct_callers: 4
    ],
    limits: [
      per_kind: 20,
      representative_calls: 10,
      representative_calls_per_edge: 3
    ]
  ],
  clone_analysis: [
    provider: :ex_dna,
    min_mass: 30,
    min_similarity: 1.0,
    max_clones: 50
  ],
  smells: [
    fixed_shape_map: [
      min_keys: 3,
      min_occurrences: 3,
      evidence_limit: 10
    ],
    behaviour_candidate: [
      min_modules: 3,
      min_callbacks: 3,
      module_display_limit: 8,
      callback_display_limit: 8
    ]
  ],
  tests: [
    hints: [
      {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]}
    ]
  ]
]
```

The `deps`, `source`, `calls`, `effects`, `boundaries`, `risk`, `candidates`, `smells`, and `tests` sections use a uniform grouped shape: the section names the concern, and nested entries name the policy direction or threshold being tuned.

## Keys

### `layers`

Assign modules to architectural layers.

```elixir
layers: [
  web: "MyAppWeb.*",
  domain: ["MyApp.Accounts", "MyApp.Billing", "MyApp.Catalog"],
  data: "MyApp.Repo"
]
```

Patterns are module-name strings with `*` wildcards. A layer may have one pattern or a list of patterns.

Reach validates layer references in dependency policy. A dependency rule that names an undeclared layer fails config validation before analysis runs.

Layer coverage can be enabled when you want every project module to belong to exactly one layer:

```elixir
checks: [
  layer_coverage: [
    require_all_modules: true,
    forbid_multiple_matches: true,
    ignore: ["Mix.Tasks.*", "MyApp.Generated.*"]
  ]
]
```

`require_all_modules` reports modules that match no layer. `forbid_multiple_matches` reports modules that match more than one layer. `ignore` excludes generated code, tasks, or other modules from coverage checks.

### `deps[:forbidden]`

Declare layer-to-layer dependencies that should not exist.

```elixir
deps: [
  forbidden: [
    {:domain, :web},
    {:data, :web},
    {:domain, :data, except: ["MyApp.Domain.Migrations"]}
  ]
]
```

`mix reach.check --arch` reports `forbidden_dependency` violations with caller, callee, call, file, and line evidence. Layer cycle violations include concrete edge witnesses so you can see which calls create the cycle.

Use `except` to allow matching caller modules through an otherwise-forbidden layer edge. Use `except_edges` when only a specific caller-to-callee seam is allowed:

```elixir
deps: [
  forbidden: [
    {:domain, :data,
     except_edges: [
       {"MyApp.Domain.RepoBoundary", "MyApp.Repo"}
     ]}
  ]
]
```

For strict architectures, use allowlist mode instead of enumerating forbidden pairs:

```elixir
deps: [
  mode: :allowlist,
  allowed: [
    web: [:domain],
    domain: [],
    data: [:domain]
  ]
]
```

In allowlist mode, same-layer calls are allowed and every cross-layer edge not listed in `allowed` is reported.

### `source[:forbidden_modules]`

Declare module names or namespaces that must not appear in the analyzed source tree. This is useful for making removed architecture impossible to reintroduce.

```elixir
source: [
  forbidden_modules: [
    "MyApp.Legacy.*",
    "MyApp.OldTaskRunner"
  ]
]
```

`mix reach.check --arch` reports `forbidden_module` violations with module, file, and line evidence.

### `source[:forbidden_files]`

Declare source paths that must not appear in the analyzed source tree.

```elixir
source: [
  forbidden_files: [
    "lib/my_app/legacy/**",
    "lib/my_app/old_task_runner.ex"
  ]
]
```

Path globs use the same `*` / `**` matching rules as module patterns. `mix reach.check --arch` reports `forbidden_file` violations.

### `calls[:forbidden]`

Declare calls that matching modules must not make. This is useful for enforcing presentation/IO boundaries or other call-level rules that are more precise than layer dependencies.

```elixir
calls: [
  forbidden: [
    {"MyApp.Domain.*", ["IO.puts", "Jason.encode!"]},
    {"MyApp.Workers.*", ["System.cmd", "File.rm"], except: ["MyApp.Workers.Cleanup"]}
  ]
]
```

Each entry is either:

```elixir
{caller_patterns, call_patterns}
{caller_patterns, call_patterns, except: except_caller_patterns}
```

Patterns use the same module/call glob syntax as layers. Call patterns may include or omit arity:

```elixir
"IO.puts"
"IO.puts/1"
"Reach.CLI.Format.render"
"Jason.encode!"
```

`mix reach.check --arch` reports `forbidden_call` violations with caller module, call, file, and line evidence.

### `effects[:allowed]`

Limit side-effect classes for matching modules.

```elixir
effects: [
  allowed: [
    {"MyApp.Pure.*", [:pure, :unknown]},
    {"MyAppWeb.*", [:pure, :read, :write, :send, :io, :unknown]}
  ],
  by_layer: [
    domain: [:pure, :exception],
    web: :any
  ]
]
```

`allowed` applies to matching module patterns. `by_layer` applies to modules assigned through `layers`; direct module-pattern policies take precedence. Use `:any` for layers where all effects are allowed.

Known effect atoms include:

- `:pure`
- `:io`
- `:read`
- `:write`
- `:send`
- `:receive`
- `:exception`
- `:nif`
- `:unknown`

Use this for architectural boundaries, not style linting. For example, keeping parsers or pure domain modules free from writes is a good fit; replacing Credo rules is not.

### `boundaries[:public]`

Declare top-level public modules that callers should use as boundaries.

```elixir
boundaries: [
  public: [
    "MyApp.Accounts",
    "MyApp.Billing"
  ]
]
```

If a caller reaches into another module under the same namespace instead of going through the declared public API, `mix reach.check --arch` may report a `public_api_boundary` violation.

### `boundaries[:internal]`

Declare modules that should be treated as internal implementation details.

```elixir
boundaries: [
  internal: [
    "MyApp.Accounts.Internal.*",
    "MyApp.Billing.Calculators.*"
  ]
]
```

Calls into these modules from outside approved callers produce `internal_boundary` violations.

### `boundaries[:internal_callers]`

Allow specific callers to reach specific internal modules.

```elixir
boundaries: [
  internal_callers: [
    {"MyApp.Accounts.Internal.*", ["MyApp.Accounts", "MyApp.Accounts.*"]}
  ]
]
```

Use this to make policy precise instead of making internal modules public.

### `risk[:changed]`

Tune changed-code risk thresholds used by `mix reach.check --changed`.

```elixir
risk: [
  changed: [
    many_direct_callers: 5,
    wide_transitive_callers: 10,
    branch_heavy: 8,
    high_risk_reason_count: 3
  ]
]
```

These thresholds control when a changed function is marked with risk reasons such as `many direct callers`, `wide transitive impact`, and `branch-heavy function`.

### `candidates[:thresholds]` and `candidates[:limits]`

Tune advisory refactoring candidate generation used by `mix reach.check --candidates` and `mix reach.inspect TARGET --candidates`.

```elixir
candidates: [
  thresholds: [
    mixed_effect_count: 2,
    branchy_function_branches: 8,
    high_risk_direct_callers: 4
  ],
  limits: [
    per_kind: 20,
    representative_calls: 10,
    representative_calls_per_edge: 3
  ]
]
```

Thresholds decide when Reach reports mixed-effect and branch-heavy extraction candidates. Limits bound candidate evidence and per-kind generation while preserving exact cycle-component detection.

### `clone_analysis`

Configure optional structural clone evidence. Reach uses clone evidence to raise confidence or find consistency drift in semantic checks; it does not emit an `ex_dna` smell by itself.


```elixir
checks: [
  baseline: ".reach-baseline.json"
]

clone_analysis: [
  provider: :ex_dna,
  min_mass: 30,
  min_similarity: 1.0,
  max_clones: 50
]

smells: [
  strict: true,
  custom_checks: [MyApp.ReachSmells.NoFoo],
  fixed_shape_map: [
    min_keys: 3,
    min_occurrences: 3,
    evidence_limit: 10
  ],
  behaviour_candidate: [
    min_modules: 3,
    min_callbacks: 3,
    module_display_limit: 8,
    callback_display_limit: 8
  ]
]
```

Reach runs ExDNA when the package is available; package consumers can disable clone evidence with `provider: false` or tune clone mass/similarity when needed.

### `checks[:baseline]`

Use a baseline to adopt `reach.check` gates in an existing codebase without hiding new issues. Baselines apply across check modes such as architecture violations and smell findings.

```bash
mix reach.check --arch --smells --write-baseline .reach-baseline.json
mix reach.check --arch --smells --baseline .reach-baseline.json
```

When a baseline is configured, known findings are suppressed before gate failure is evaluated. New architecture violations still fail `--arch`, and new smell findings fail when `--strict` or `smells: [strict: true]` is enabled.

### `smells[:strict]`

`mix reach.check --smells` is advisory by default. Set `strict: true` or pass `--strict` to fail on non-baseline smell findings.

### `smells[:custom_checks]`

Projects can add local smell checks by implementing `Reach.Smell.Check` in their own application and listing the modules in `.reach.exs`.

```elixir
defmodule MyApp.ReachSmells.NoFoo do
  @behaviour Reach.Smell.Check

  alias Reach.Smell.Finding

  @impl true
  def run(project) do
    for {_id, node} <- project.nodes,
        node.type == :call,
        node.meta[:module] == MyApp.Foo do
      Finding.new(
        kind: :my_app_no_foo,
        message: "Use MyApp.Bar instead of MyApp.Foo",
        location: location(node)
      )
    end
  end

  defp location(%{source_span: %{file: file, start_line: line}}), do: "#{file}:#{line}"
  defp location(_node), do: "unknown"
end
```

Enable it explicitly:

```elixir
smells: [
  strict: true,
  custom_checks: [MyApp.ReachSmells.NoFoo]
]
```

Custom checks run alongside Reach's built-in smell checks and participate in `--strict` and baseline filtering. A custom check must implement `Reach.Smell.Check` and define `run/1`. See the custom smells guide for a deeper walkthrough.

### Built-in smell examples

Reach combines generic Elixir smells with plugin-provided Phoenix, Ecto, and Oban checks. Examples include:

| Kind | Example flagged pattern | Prefer |
| --- | --- | --- |
| `unsafe_atom_creation` | `String.to_atom(input)` | explicit mapping or `String.to_existing_atom/1` |
| `unsafe_binary_to_term` | `:erlang.binary_to_term(payload)` | `:erlang.binary_to_term(payload, [:safe])` for untrusted input |
| `missing_external_resource` | `@schema File.read!("priv/schema.json")` | add matching `@external_resource "priv/schema.json"` |
| `ecto_float_money` | `field :amount, :float` / `add :price, :float` | integer cents or `Decimal` |
| `ecto_repo_call_in_loop` | `Enum.map(users, &Repo.get(Order, &1.order_id))` | preload or batch query |
| `ecto_filter_after_repo_all` | `Repo.all(User) |> Enum.filter(...)` | push predicates into the Ecto query |
| `ecto_count_after_repo_all` | `Repo.all(User) |> length()` | `Repo.aggregate/3`, `Repo.exists?/1`, or query aggregate |
| `ecto_interpolated_fragment` | `fragment("name = '#{name}'")` | `fragment("name = ?", ^name)` |
| `ecto_interpolated_repo_query` | `Repo.query("select ... #{input}")` | parameterized SQL |
| `ecto_implicit_cross_join` | `from u in User, p in Post` | explicit `join:` with `on:` |
| `ecto_unpinned_query_value` | `where: u.id == user_id` | `where: u.id == ^user_id` |
| `oban_atom_args` | `%Oban.Job{args: %{user_id: id}}` | match string keys: `%{"user_id" => id}` |
| `oban_struct_args` | `MyWorker.new(%{user: %User{}})` | store IDs / JSON primitives |
| `phoenix_assign_async_captures_socket` | `assign_async(socket, :x, fn -> socket.assigns.x end)` | copy needed assign values before the callback |
| `phoenix_assign_new_refreshed_value` | `assign_new(socket, :current_user, ...)` inside `mount/3` | use `assign/3` for values refreshed every mount |
| `phoenix_pubsub_subscribe_without_connected` | `Phoenix.PubSub.subscribe(...)` in `mount/3` | guard with `if connected?(socket)` |

Some intentionally context-sensitive checks, such as dynamic `Phoenix.HTML.raw/1`, are kept available as direct check modules but are not enabled by the default Phoenix plugin because real applications often use them in sanitizer, markdown, or compiler helpers.

### `smells[:fixed_shape_map]` and `smells[:behaviour_candidate]`

Use smell-specific thresholds when a codebase intentionally uses small map contracts, when you want stronger pressure toward structs/contracts, or when behaviour-candidate hints are too noisy for small module families.

### `tests[:hints]`

Suggest tests for changed paths.

```elixir
tests: [
  hints: [
    {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]},
    {"lib/my_app_web/live/**", ["test/my_app_web/live"]}
  ]
]
```

`mix reach.check --changed` combines these hints with nearby test paths and caller impact data.

## Compatibility aliases

Reach accepts the previous flat keys as compatibility aliases, but new configs should use the grouped form.

| Preferred | Compatibility alias |
| --- | --- |
| `deps[:forbidden]` | `forbidden_deps` |
| `calls[:forbidden]` | `forbidden_calls` |
| `effects[:allowed]` | `allowed_effects` |
| `boundaries[:public]` | `public_api` |
| `boundaries[:internal]` | `internal` |
| `boundaries[:internal_callers]` | `internal_callers` |
| `tests[:hints]` | `test_hints` |
| `source[:forbidden_modules]` | `forbidden_modules` |
| `source[:forbidden_files]` | `forbidden_files` |

## Validation

Reach validates `.reach.exs` shape and reports `config_error` entries for:

- unknown top-level or grouped keys
- invalid `layers`
- invalid `deps[:forbidden]`
- invalid `source[:forbidden_modules]`
- invalid `source[:forbidden_files]`
- invalid `calls[:forbidden]`
- invalid `effects[:allowed]`
- invalid `boundaries[:public]`
- invalid `boundaries[:internal]`
- invalid `boundaries[:internal_callers]`
- invalid `risk[:changed]` thresholds
- invalid `candidates[:thresholds]`
- invalid `candidates[:limits]`
- invalid `smells[:fixed_shape_map]`
- invalid `smells[:behaviour_candidate]`
- invalid `clone_analysis`
- invalid `tests[:hints]`

## Practical guidance

Start permissive and tighten gradually:

1. Define broad layers.
2. Add only the forbidden dependencies you are confident about.
3. Add boundary policies for namespaces with clear public/internal modules.
4. Add effect policies for modules that should stay pure or effect-limited.
5. Tune `risk[:changed]`, `candidates`, and `smells` thresholds to match your repository size and tolerance for advisory output.
6. Run `mix reach.check --arch --format json` in CI once the policy is stable.

Refactoring candidates are advisory. They include `confidence`, `actionability`, and `proof` fields. Treat those fields as preconditions for editing, especially for cycle and extraction candidates.
