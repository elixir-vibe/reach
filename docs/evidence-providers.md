# Evidence providers

Reach keeps reusable analysis facts in evidence providers. Smells, checks, and refactoring candidates decide which facts become user-facing policy.

## Provider shape

An AST evidence provider implements `Reach.Evidence.Provider` and exposes lightweight metadata:

```elixir
@behaviour Reach.Evidence.Provider

def family, do: :stdlib

def kinds, do: [:manual_flat_map]

def collect_ast(ast), do: [%Reach.Evidence.Fact{}]
```

Providers are discovered through `Reach.Evidence.ast_providers/1` and dependency-specific plugin callbacks. The behaviour standardizes discovery while allowing each provider to use the traversal or proof appropriate to its evidence.

Most providers should emit `Reach.Evidence.Fact` values. Domain-specific providers may use richer structs temporarily when downstream checks need specialized fields, but scanner-facing facts should converge on this common shape.

Evidence facts should carry at least:

- `:family` — provider family such as `:stdlib`, `:jason`, or `:map_contract`;
- `:kind` — stable atom for the observed fact;
- `:message` — short maintainer-facing explanation;
- `:replacement` — suggested abstraction or API when one is known;
- `:meta` — source metadata, usually including `:line` and optionally `:column`;
- `:confidence` — coarse confidence such as `:high` or `:medium`.

## Capability bypass evidence

`Reach.Evidence.Bypass` normalizes facts showing that code reimplements an available capability. Existing provider families remain stable, while `fact.data` identifies the shared category:

```elixir
%Reach.Evidence.Fact{
  family: :jason,
  kind: :hand_rolled_json_encoder,
  data: %{
    category: :capability_bypass,
    provider: Jason,
    capability: :json_encoding,
    origin: :plugin_pattern
  }
}
```

Origins distinguish standard-library patterns, plugin-specific patterns, and project-to-dependency clones. Consumers can therefore aggregate bypass evidence without hardcoding provider families. Plugin activation remains the dependency gate; do not add a second capability-discovery callback.

When `clone_analysis[:include_deps]` is enabled, ExDNA analyzes direct dependency `lib/` sources together with project sources and retains only clone families containing both origins. Those families become `:dependency_bypass` facts with `origin: :dependency_clone`. Dependency code is read as source only; Reach does not compile or load it.

Collect project-level dependency bypass facts with:

```elixir
Reach.Evidence.dependency_bypass(project, config)
```

This API is separate from per-file AST providers because clone evidence needs the whole project and dependency source roots. Exact Type-I dependency clones are also surfaced as advisory `:reuse_dependency` results from `mix reach.check --candidates`; weaker clone types remain evidence-only.

## External-data boundary evidence

`Reach.Evidence.ExternalDataBoundary` performs source-only intrafunction provenance analysis. Decoder ownership stays in plugins through `Reach.Plugin.external_data_source/2`; the generic provider knows only platform storage and process boundaries such as `:persistent_term`, ETS, process dictionaries, messages, and GenServer state returns.

The provider follows direct assignments, aliases, `case`, `with`, `if`, and container wrapping. Explicit calls, map construction, or struct construction stop provenance, treating them as possible normalization boundaries rather than guessing through transformations. Collect project-level facts with:

```elixir
Reach.Evidence.external_data_boundaries(project)
```

Raw facts include intentionally dynamic stores. The high-confidence `decoded_boundary_leakage` smell therefore requires downstream use of at least two distinct literal map keys in the same module. Generic decoded stores accessed only through dynamic keys, sandbox payloads, and transient wire envelopes remain evidence-only. Fixed-contract facts also retain the boundary function and matching literal-key consumer functions, allowing candidate generation to compute a precise, bounded impact list without re-parsing source. `Reach.Evidence.Impact` owns the reusable call-graph traversal consumed by both boundary candidates and target-local `Reach.Inspect.Impact`.

## Parameter-shape evidence

`Reach.Evidence.ParameterShape` follows literal fixed-shape maps through assignments and statically resolved project calls, then groups the observed key sets by target parameter. Facts include callers, shape variants, core/union/optional keys, a normalized key entropy (`1 - core/union`), strict and defensive callee key consumption, parameter role, literal variant tags, companion-argument dispatch, and explicit multi-clause or guarded map/struct dispatch.

```elixir
Reach.Evidence.parameter_shapes(project)
```

Lineage is deliberately transparent-only: map literals flow through variables and assignments, but Reach does not descend through arbitrary calls or containers where a nested map could be mistaken for the whole argument. Function-head map patterns are not treated as exact runtime shapes. The `parameter_shape_entropy` smell requires multiple callers and variants, domain-role naming, multiple consumed contract keys including a strictly consumed key that differs between variants, and excludes defensive optional-field access and tagged, companion-selected, clause-dispatched, or guarded unions.

## Representation-overlap evidence

`Reach.Evidence.RepresentationOverlap` compares source-declared `defstruct` fields with bare atom-key map constructions in other modules. Facts retain both locations, shared and exclusive keys, Jaccard similarity, entity-name evidence, direct projection sources, map role, and immediate normalization targets.

```elixir
Reach.Evidence.representation_overlaps(project)
```

The evidence layer keeps all overlaps above its configurable shape threshold. The `same_entity_representation` smell promotes only domain-role maps with entity-bearing names. It excludes map patterns and explicit `__struct__` values before shape comparison, then keeps direct and caller-level normalization targets, nested projection provenance, assigned roles, and declared map conversions visible on facts. Promotion excludes adapter/presentation/serialization boundaries, ambiguous entity names, accumulators, projections from the matching entity, normalized maps, and structs that declare conversions such as `from_map/1` or `to_map/1`. Framework-generated structs remain plugin territory; the generic provider reads only explicit source declarations.

## Nil-parameter evidence

`Reach.Evidence.NilParameter` combines call evidence with per-function control flow. A parameter becomes nil-capable only when Reach observes a literal nil argument, a nil default, or a matching nil clause. Nil-clause evidence retains the other parameter patterns, so a clause for `(:with_cte, nil)` does not make the same parameter nullable in an unrelated `(:from, value)` clause.

For each applicable clause, the provider records field/dynamic receiver uses, strict `Map` operations, and calls into project functions whose corresponding parameter rejects nil in every clause. Default-arity wrappers inherit the full function's proven parameter requirement, while call evidence maps supplied arguments around the exact omitted default slots. Unknown dynamic receivers are not resolved to coincidentally named local functions.

Reach then builds the existing `Reach.ControlFlow` graph and uses `Reach.Dominator` to verify that a non-nil pattern, guard, branch, prior exhaustive nil clause, or dominating normalization protects each use. Successful `with` patterns stop old provenance after the binding but not in its right-hand side. Short-circuit conditions, `if`/`unless`/`cond` and `case` paths, literal/defaulted companion arguments, comprehensions, repeated-variable dispatch, nested callback shadowing, and final wildcard fallbacks are modeled separately. Uses inside guards are safe under Elixir guard semantics, and static module calls are distinguished from dynamic receiver calls by IR arity.

```elixir
Reach.Evidence.nil_parameters(project)
```

Facts retain nil source locations, exact use locations, dominating guard vertices, clause/promotion context, function visibility, and recursive-helper provenance. The provider intentionally does not infer nilability from unknown callers or infer external library contracts beyond a small platform-level strict-map set. The smell layer promotes direct defaults, late nil fallbacks preempted by strict clauses, unconditional literal-call hazards, and literal-gated calls into project functions with proven non-nil parameters; weaker path-dependent facts remain queryable evidence.

## Return-contract evidence

`Reach.Evidence.ReturnContract` collects terminal expressions across function clauses and explicit `case`, `cond`, `if`, `with`, `receive`, and `try` branches. Outcomes retain structural classes, exact tagged-tuple arity, source lines, nested identical tags, sentinel-clause provenance, closed direct `@spec` shapes, and whether the function is marked `@impl` or recognized as a source-declared OTP callback.

Unknown calls and implicit `with` fallthrough remain dynamic evidence rather than guessed return types. Function-level `rescue`, `catch`, and `else` are modeled as `try` semantics, so transformed successful values are not incorrectly counted as terminal returns. Collect project-level facts with:

```elixir
Reach.Evidence.return_contracts(project)
```

The smell policy promotes only high-confidence `:ok` contract conflicts backed by a closed-spec mismatch, an asymmetric raw error beside tagged errors, or a tagged nil/empty sentinel beside raw successful values. Bare/tagged optional payloads, tuple-arity differences, explicit/open unions, conventional `{:ok, value} | {:error, reason}`, custom sentinel failures, state-machine tuples, dynamic forwarding, explicit or source-declared OTP callbacks, and nested same-tag results remain evidence-only.

## Accepted-domain fallback evidence

`Reach.Evidence.TotalFunctionLaundering` records private unary parsers whose literal or membership-guarded clauses preserve a closed value domain while a final catch-all returns one accepted value.

```elixir
Reach.Evidence.total_function_laundering(project)
```

Facts retain the observed input/output domain, same-named literal type domain, fallback, clause locations, and whether the fallback has its own explicit accepted-input clause. An explicit fallback clause establishes an intentional default-normalization policy and remains evidence-only. The `total_function_laundering` smell promotes only the narrower case where the fallback is declared by the type but cannot be selected through an explicit domain clause, so unsupported input is indistinguishable from an otherwise buried accepted value.

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

A calibrated AST provider can be promoted without duplicating collection logic:

```elixir
defmodule MyPlugin.Smells.CapabilityBypass do
  use Reach.Smell.Check.Evidence,
    provider: MyPlugin.Evidence.CapabilityBypass
end
```

The plugin must still register that smell check explicitly. Normalized bypass evidence is not automatically promoted merely because it exists.

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
