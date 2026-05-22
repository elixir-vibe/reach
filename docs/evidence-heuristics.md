# Evidence Heuristics Backlog

Reach keeps promising maintainability ideas as evidence providers first. Do not discard a good idea just because a naive smell would be noisy; add stronger context, mine real history, and only promote it to a smell or candidate when the evidence is useful. Provider API and boundary conventions are documented in `docs/evidence-providers.md`.

## Evidence vs smells

Evidence is an observed fact; a smell is a user-facing judgment.

Evidence providers answer: "what facts did we observe in source, IR, or a project graph?" They return reusable facts with kind, location, confidence, and domain-specific fields. Evidence modules must not decide whether something should fail CI or be shown as a warning.

Policy consumers answer: "what should Reach do with those facts?"

- `Reach.Smell.*` turns evidence into code-quality findings shown by `mix reach.check --smells`.
- `Reach.Check.*` turns evidence into CI/release policy output or advisory refactoring candidates.
- Plugins expose dependency-specific evidence and smells only when the dependency is present.
- Corpus scripts can scan evidence directly before a heuristic is promoted to a smell or candidate.

This separation lets Reach keep promising patterns without shipping noisy warnings. The promotion path is:

```text
idea → evidence provider → corpus scan → stronger heuristic → smell/check/candidate
```

Use evidence when a signal may be useful in multiple contexts or still needs corpus tuning. Use a smell only when the message is ready to be user-facing and appropriate for strict smell gates.

## Standard library bypass

Implemented high-confidence families live in focused modules under `Reach.Evidence.StandardLibraryBypass.*` and are aggregated by `Reach.Evidence.StandardLibraryBypass`. Simple syntactic shapes use `Reach.Evidence.PatternRunner`/ExAST pattern matching where practical; flow-sensitive or multi-statement shapes may use custom AST callbacks:

- `Path.basename/1` and `Path.extname/1` for path-like `String.split` pipelines.
- `URI.parse/1` and `URI.decode_query/1` for URI/query-like splits.
- `Enum.flat_map/2` for direct `Enum.map` followed by `List.flatten/1` or `Enum.concat/1`.
- `Map.update/4` for paired `Map.has_key?`/`Map.put` branches that update the same map/key without relying on a `nil` sentinel.
- `Enum.frequencies/1` and `Enum.frequencies_by/2` for reduce-based count maps with `%{}` initial accumulator, exact increment-by-one logic, and no extra payload work.
- `Enum.flat_map/2` for reduce-based `acc ++ mapped_list` callbacks with an empty list accumulator.
- `Enum.flat_map/2` for order-safe prepend/reverse reducers shaped as `Enum.reverse(chunk, acc)` followed by a final `Enum.reverse/1`.
- `Map.update!/3` when code fetches a required existing key and immediately puts the transformed value back.

Corpus review notes:

- A Hex corpus pass over 6,882 packages produced 540 standard-library evidence hits after tuning, with no scanner stderr.
- `Enum.map(...) |> Enum.concat()` samples were direct `Enum.flat_map/2` opportunities and remain high confidence.
- `Enum.map(...) |> List.flatten()` is intentionally medium confidence: sampled uses often flatten mapper output, but recursive flattening may be semantically required.
- Reduce-based append evidence now ignores `acc ++ [expr]` because sampled hits were `Enum.map/2` shapes, not `Enum.flat_map/2` shapes. It still flags `acc ++ expand(item)` where the appended expression is a list-producing transformation.
- `Map.update/4`, `Map.update!/3`, `Enum.frequencies/1`, `Enum.frequencies_by/2`, Path, and URI samples matched the intended replacement families.

Promising mined families that need stronger constraints before implementation:

- Other `Enum.flat_map/2` prepend/reverse variants; avoid `chunk ++ acc |> Enum.reverse` because it reverses each chunk's internal order.
- `URI.parse/1` for authority parsing such as `String.split(str, ":", parts: 2)`, but only for URI/host/endpoint variable names or surrounding URI semantics.
- `Path.basename/1` / `Path.extname/1` for filename construction, but avoid generic labels/slugs.

## Map contracts

Implemented evidence:

- local fixed-shape map creation followed by key reads/updates;
- local function return shape followed by callsite reads;
- project-level remote return-shape contracts for maps returned by one module and read in another;
- shallow alias tracking for map bindings and returned map variables;
- escape target metadata for maps passed wholesale into calls;
- role metadata such as `:domain`, `:assigns`, `:accumulator`, `:external_payload`, `:options`, and `:unknown`;
- plugin evidence refinement, e.g. Jason marks maps passed to `Jason.encode/1,2` or `Jason.encode!/1,2` as external payloads;
- advisory struct, boundary, or typed-map contract candidates when evidence is repeated, return-shape based, or grouped into a similar-shape family.

Promising upgrades:

- richer project-level return-shape evidence through `Reach.Project.Query`/IR instead of source-only AST matching;
- confidence boosts when the same shape crosses module boundaries;
- plugin refinements for Phoenix/LiveView assigns, request params, component attrs, and other framework-owned map roles;
- key-source and drift evidence that explains where each observed key came from and how similar shapes diverge across files.

## Mined examples

- Hologram has direct `Enum.map(... ) |> Enum.concat/List.flatten` examples in recursive file and template expansion helpers; these validate the direct `Enum.flat_map/2` heuristic.
- Xamal replaced `String.split(str, ":", parts: 2)` authority parsing with `URI.parse("//#{str}")`; this remains a backlog URI heuristic until variable/context constraints are strong enough.
- Jido history contains `Enum.frequencies/1` and `Map.update` replacements in dependency and telemetry code; these validate count-map and paired-update families but also show why payload aggregation must be excluded.
- Reach's own history has append-in-reduce cleanups; reduce-based `Enum.flat_map/2` should stay limited to obvious `acc ++ mapped_list` shapes unless order proof is explicit.

## JSON/Jason

Jason-specific hand-roll detection belongs in `Reach.Plugins.Jason`, not generic standard-library heuristics. Future JSON work should stay plugin-owned and dependency-gated.
