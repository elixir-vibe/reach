# Evidence Heuristics Backlog

Reach keeps promising maintainability ideas as evidence providers first. Do not discard a good idea just because a naive smell would be noisy; add stronger context, mine real history, and only promote it to a smell or candidate when the evidence is useful.

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

Implemented high-confidence families live in focused modules under `Reach.Evidence.StandardLibraryBypass.*` and are aggregated by `Reach.Evidence.StandardLibraryBypass`:

- `Path.basename/1` and `Path.extname/1` for path-like `String.split` pipelines.
- `URI.parse/1` and `URI.decode_query/1` for URI/query-like splits.
- `Enum.flat_map/2` for direct `Enum.map` followed by `List.flatten/1` or `Enum.concat/1`.
- `Map.update/4` for paired `Map.get`/`Map.put` or `Map.has_key?`/`Map.put` branches that update the same map/key.
- `Enum.frequencies/1` and `Enum.frequencies_by/2` for reduce-based count maps with `%{}` initial accumulator, exact increment-by-one logic, and no extra payload work.
- `Enum.flat_map/2` for reduce-based `acc ++ mapped_list` callbacks with an empty list accumulator.
- `Enum.flat_map/2` for order-safe prepend/reverse reducers shaped as `Enum.reverse(chunk, acc)` followed by a final `Enum.reverse/1`.
- `Map.update!/3` when code fetches a required existing key and immediately puts the transformed value back.

Promising mined families that need stronger constraints before implementation:

- Other `Enum.flat_map/2` prepend/reverse variants; avoid `chunk ++ acc |> Enum.reverse` because it reverses each chunk's internal order.
- `URI.parse/1` for authority parsing such as `String.split(str, ":", parts: 2)`, but only for URI/host/endpoint variable names or surrounding URI semantics.
- `Path.basename/1` / `Path.extname/1` for filename construction, but avoid generic labels/slugs.

## Map contracts

Implemented evidence:

- local fixed-shape map creation followed by key reads/updates;
- local function return shape followed by callsite reads;
- advisory `:introduce_struct_contract` candidates when evidence is repeated or return-shape based.

Promising upgrades:

- cross-file return-shape evidence through `Reach.Project.Query` instead of source-only local calls;
- confidence boosts when the same shape crosses module boundaries;
- lower confidence for accumulator/report names unless shape is returned or reused;
- explicit exclusions for external payload boundaries such as `params`, `payload`, `body`, `json`, and `metadata` unless internal reads dominate.

## Mined examples

- Hologram has direct `Enum.map(... ) |> Enum.concat/List.flatten` examples in recursive file and template expansion helpers; these validate the direct `Enum.flat_map/2` heuristic.
- Xamal replaced `String.split(str, ":", parts: 2)` authority parsing with `URI.parse("//#{str}")`; this remains a backlog URI heuristic until variable/context constraints are strong enough.
- Jido history contains `Enum.frequencies/1` and `Map.update` replacements in dependency and telemetry code; these validate count-map and paired-update families but also show why payload aggregation must be excluded.
- Reach's own history has append-in-reduce cleanups; reduce-based `Enum.flat_map/2` should stay limited to obvious `acc ++ mapped_list` shapes unless order proof is explicit.

## JSON/Jason

Jason-specific hand-roll detection belongs in `Reach.Plugins.Jason`, not generic standard-library heuristics. Future JSON work should stay plugin-owned and dependency-gated.
