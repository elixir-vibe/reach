# Concepts

Reach translates source code into an intermediate representation, builds control/data/call relationships, and combines them into a program dependence graph.

## Control flow

Control-flow graphs show branch structure inside functions. Reach keeps function CFGs acyclic and uses block-quality checks to ensure rendered blocks cover source lines without duplicates.

## Call graph

The call graph connects caller and callee functions. Reach uses it for dependency trees, impact analysis, module coupling, hotspots, and why-path explanations.

## Data flow

Data-flow edges track definitions, uses, parameters, returns, and cross-function value movement. Trace commands use these edges for taint and variable workflows.

## Effects

Reach classifies calls into effect categories such as pure, IO, read, write, send, receive, exception, NIF, and unknown. Effect evidence powers boundaries, smells, and refactoring candidates.

## Smells

Reach detects structural code smells in two layers:

**Source smells** use the `Reach.Smell.Check.Source` DSL for source-level rules. Simple rules use ExAST's `~p` sigil and selectors; hot or shape-sensitive rules can use `smell(..., mode: :ast)` callbacks over Sourceror AST nodes. These run per-file with shared source/AST/zipper caches and inferred source prefilters.

**Semantic smells** use Reach's own IR with effects, data flow, call graph, and clone evidence — redundant computation, loop anti-patterns, dual key access, fixed-shape maps, behaviour candidates, return-contract drift, unsafe dynamic atom creation, and unsafe `binary_to_term/1`.

**AST smells** use Sourceror source AST when the source shape matters more than IR — compile-time file reads without `@external_resource`, Ecto implicit cross joins, interpolated SQL, and unpinned Ecto query values.

Source smells are declared with one `smell` DSL:

```elixir
use Reach.Smell.Check.Source

smell ~p[Enum.reverse(_) |> hd()], :suboptimal,
      "traverses twice; use List.last/1"

smell(
  from(~p[Enum.drop(_, amount) |> Enum.take(_)]) |> where(not match?({:-, _, [_]}, ^amount)),
  :eager_pattern,
  "use Enum.slice/3"
)

smell(
  :boolean_case,
  :suboptimal,
  "case on boolean with true/false clauses; use if/else",
  mode: :ast,
  prefilter: {:all, ["case"]}
)

defp boolean_case({:case, meta, [subject, clauses]}) do
  if boolean_subject?(subject) and boolean_case_clauses?(clauses), do: {:ok, meta}
end

defp boolean_case(_node), do: nil
```

Semantic smells use the standard `Reach.Smell.Check` behaviour with IR helpers like `inside_loop?/2`, `callback_body/1`, and `statement_pairs/1`.

AST-backed smells can use `Reach.Smell.Check.AST` and implement `scan_ast/2`:

```elixir
defmodule MyApp.ReachSmells.NoCompileTimeRead do
  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:my_app_compile_time_read]

  defp scan_ast(ast, file) do
    # inspect Sourceror AST and return Finding structs
  end
end
```

Projects can also define local semantic smell checks and enable them with `smells: [custom_checks: [...]]` in `.reach.exs`.

```elixir
defmodule MyApp.ReachSmells.NoFoo do
  @behaviour Reach.Smell.Check

  def run(project) do
    # return Reach.Smell.Finding structs
  end
end
```

## Clone analysis

Optional clone evidence (via ExDNA) enriches semantic smell confidence. Clone families inform structural consistency checks: return-contract drift, side-effect order drift, map-contract drift, validation drift, and behaviour extraction candidates.

## Plugins

Plugins extend Reach with framework-specific semantics: effect classification, trace presets, behaviour labels, visualization filtering, and graph edges. Built-in plugins auto-detect Phoenix, Ecto, Oban, Ash, GenStage, Jido, OpenTelemetry, and Gettext. Language frontends (JavaScript/Gleam) are also plugin-discovered.

## OTP analysis

OTP checks identify GenServer state access, GenStatem transitions, missing handlers, dead replies, supervision, process dictionary/ETS coupling, and cross-process resource sharing.
