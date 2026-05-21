# Evidence Heuristics Backlog

Reach keeps promising maintainability ideas as evidence providers first. Do not discard a good idea just because a naive smell would be noisy; add stronger context, mine real history, and only promote it to a smell or candidate when the evidence is useful.

## Standard library bypass

Implemented high-confidence families:

- `Path.basename/1` and `Path.extname/1` for path-like `String.split` pipelines.
- `URI.parse/1` and `URI.decode_query/1` for URI/query-like splits.
- `Enum.flat_map/2` for direct `Enum.map` followed by `List.flatten/1` or `Enum.concat/1`.
- `Map.update/4` for paired `Map.get`/`Map.put` or `Map.has_key?`/`Map.put` branches that update the same map/key.
- `Enum.frequencies/1` and `Enum.frequencies_by/2` for reduce-based count maps with `%{}` initial accumulator, exact increment-by-one logic, and no extra payload work.

Promising mined families that need stronger constraints before implementation:

- `Map.update!/3` when code fetches a required existing key and immediately puts the transformed value back.
- `Enum.flat_map/2` variants where a reduce accumulates `acc ++ list` or reverses concatenated chunks.
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

## JSON/Jason

Jason-specific hand-roll detection belongs in `Reach.Plugins.Jason`, not generic standard-library heuristics. Future JSON work should stay plugin-owned and dependency-gated.
