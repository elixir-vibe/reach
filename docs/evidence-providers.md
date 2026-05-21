# Evidence providers

Reach keeps reusable analysis facts in evidence providers. Smells, checks, and refactoring candidates decide which facts become user-facing policy.

## Provider shape

An AST evidence provider exposes lightweight metadata:

```elixir
def family, do: :stdlib

def kinds, do: [:manual_flat_map]

def collect_ast(ast), do: [%Reach.Evidence.Fact{}]
```

Providers are discovered through `Reach.Evidence.ast_providers/1` and dependency-specific plugin callbacks. Keep the API small until several providers need a stronger behaviour.

Most providers should emit `Reach.Evidence.Fact` values. Domain-specific providers may use richer structs temporarily when downstream checks need specialized fields, but scanner-facing facts should converge on this common shape.

Evidence facts should carry at least:

- `:family` — provider family such as `:stdlib`, `:jason`, or `:map_contract`;
- `:kind` — stable atom for the observed fact;
- `:message` — short maintainer-facing explanation;
- `:replacement` — suggested abstraction or API when one is known;
- `:meta` — source metadata, usually including `:line` and optionally `:column`;
- `:confidence` — coarse confidence such as `:high` or `:medium`.

## Boundaries

Evidence providers must not emit `Reach.Smell.Finding` and must not depend on CLI rendering or command modules. User-facing policy belongs in:

- `Reach.Smell.*` for local code-shape findings shown by `mix reach.check --smells`;
- `Reach.Check.*` for CI/release policy and advisory candidates;
- plugin smell/check modules for dependency-specific user-facing output.

Plugin-gated evidence belongs under `Reach.Plugins.*.Evidence`, not in generic evidence modules. Generic providers must not hardcode framework policy such as Phoenix, Ecto, Oban, Ash, Jido, or JSON-library-specific semantics.

## Plugin refinement

Plugins may refine evidence facts after generic providers collect them. Use this when the generic evidence is framework-neutral but a dependency can add semantic context:

```elixir
def refine_evidence(%Reach.Evidence.MapContract.Contract{escapes: escapes}, _context) do
  if Enum.any?(escapes, &jason_encode?/1) do
    %{role: :external_payload}
  else
    :unchanged
  end
end


def refine_evidence(_evidence, _context), do: :unchanged
```

Reach applies refinements through:

```elixir
Reach.Plugin.refine_evidence(plugins, evidence, context)
```

A refinement may return:

- `:unchanged` — keep the evidence as-is;
- a map of updates — merge annotations such as `role: :external_payload` or `confidence: :medium`;
- a replacement evidence struct of the same type.

Refinement must stay evidence-level. Plugins should annotate facts, confidence, roles, or metadata; they must not emit `Reach.Smell.Finding` or decide candidate policy directly. Smells/checks/candidates consume the refined evidence later.

Current example: `Reach.Evidence.MapContract` records generic escape targets such as `Jason.encode!(data)`. `Reach.Plugins.Jason` refines those contracts to `role: :external_payload`, which lets candidate generation suggest a boundary contract instead of a domain struct.

## Pattern matching

Prefer `Reach.Evidence.PatternRunner` for simple syntactic shapes:

```elixir
import ExAST.Sigil

PatternRunner.run(
  ast,
  [
    manual_flat_map:
      {~p[Enum.map(_, _) |> List.flatten()],
       fn _match ->
         %{
           kind: :manual_flat_map,
           message: "Enum.map followed by flatten allocates an intermediate nested list; use Enum.flat_map/2",
           replacement: "Enum.flat_map/2",
           confidence: :high
         }
       end}
  ],
  family: :stdlib
)
```

Use the pattern as the seed and keep context checks in the builder callback. For example, `StandardLibraryBypass.PathURI` uses ExAST to find `String.split` shapes, then verifies that the subject variable looks path- or URI-like.

Use custom AST traversal, project queries, or data-flow logic when evidence requires proof beyond a single syntactic shape, such as:

- reduce-based `Enum.frequencies/1` or `Enum.flat_map/2` reimplementations;
- multi-statement `Map.fetch!/2` then `Map.put/3` updates;
- implicit map contracts that depend on construction, reads, updates, and callsite return usage.

## Promotion workflow

Use this path for new maintainability ideas:

```text
idea → evidence provider → corpus scan → stronger heuristic → smell/check/candidate
```

Run corpus scans before promoting noisy facts:

```bash
MIX_ENV=test mix run scripts/evidence_corpus_scan.exs -- --kind all /path/to/project
```

The scanner should use provider discovery and plugin refinement, producing facts even when they are not yet exposed as smells. This keeps promising heuristics available for tuning without turning early signals into noisy user-facing warnings.
