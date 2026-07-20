# Evidence Heuristics

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

`Enum.map(...) |> Enum.concat()` is a direct `Enum.flat_map/2` opportunity. `Enum.map(...) |> List.flatten()` remains medium confidence because recursive flattening may be semantically required. Reduce-based append evidence ignores `acc ++ [expr]`, which is an `Enum.map/2` shape, while retaining `acc ++ expand(item)` when the appended expression is list-producing.

## Dependency capability bypass

`Reach.Evidence.Bypass` normalizes standard-library, plugin-pattern, and project-to-dependency clone facts. With `clone_analysis[:include_deps]` enabled, ExDNA reads direct dependency `lib/` sources and retains only clone families spanning project and dependency origins.

Exact ExDNA Type-I clones may become advisory `:reuse_dependency` candidates. Type-II/Type-III or lower-similarity matches remain evidence-only. Candidates require review of the dependency's supported public API; Reach does not recommend calling copied internal functions solely because source matches.

## Project clone consolidation

Exact ExDNA Type-I families containing at least two distinct whole project functions can produce advisory `:consolidate_clone` candidates. Reach requires the matched ExDNA fragment to be a complete `def`/`defp`, rather than an identical expression embedded in otherwise different functions. It also excludes behaviour- and `use`-owned modules, where matching callbacks commonly represent intentional parallel implementations.

Reach ranks each function deterministically by module stability and efferent coupling, then by evidence completeness, direct callers, and source location. The selected function is a review target, not a behavioral-equivalence claim. Type-II/Type-III families remain evidence-only. Candidates list every sibling implementation and require maintainers to compare return contracts, errors, effects, and tests before moving callers. Public entrypoints may remain as thin adapters when they preserve an intentional API boundary.

## Regex parsing of structured formats

`mix reach.trace --pattern regex-on-structured` uses the project data-flow graph rather than source proximity. Its primary route starts at `File.read/1`, `File.read!/1`, or `File.stream!/1,3` with a static `.xml`, `.html`, `.htm`, `.heex`, `.eex`, `.ex`, `.exs`, or `.rs` path and ends at Regex APIs, regex `=~`, or regex-based `String.split`. A fallback accepts dynamic paths only when the sink contains a structure-shaped regex literal such as an XML/HTML tag, `defmodule`, `defstruct`, or `fn\\s`.

The preset remains a trace workflow rather than a smell. Promotion would require broader path review and explicit suppression policy for intentional release/build scripts.

## Decoded external data crossing boundaries

`Reach.Evidence.ExternalDataBoundary` tracks plugin-owned decoder results into generic storage and process boundaries without compiling source. Jason and Poison own their decode call shapes; the generic provider owns `:persistent_term`, ETS, process dictionaries, sends, GenServer calls/starts, and GenServer callback state returns. Explicit struct/map construction and transformation calls stop provenance.

Raw boundary crossings are evidence. Promotion to the high-confidence `decoded_boundary_leakage` smell additionally requires at least two distinct downstream literal map keys in the same module. This preserves intentionally dynamic stores while finding decoded fixed-shape contracts that lose provenance before consumers apply string-key defaults. Sandbox payloads and transient transport envelopes identified by module role plus wire-envelope keys remain evidence because preserving their upstream representation is part of the boundary contract.

The same fixed-contract evidence produces advisory `introduce_boundary_contract` candidates. Each candidate names the decoder and exact storage/process boundary, emits a draft `@enforce_keys`/`defstruct` when keys are valid fields (otherwise a validation-schema draft), and computes a bounded blast radius from the boundary and literal-key consumer functions through the shared `Reach.Evidence.Impact` traversal also used by `Reach.Inspect.Impact`.

## Broad map contracts and dual-key fallbacks

`Reach.Evidence.MapContract` retains literal key accesses, parameter origins, access strictness, and atom/string fallback structure as reusable facts. Smell promotion is intentionally narrower than the evidence.

`broad_map_contract` requires at least three literal keys from one direct broad-map parameter origin and at least one strict `Map.fetch!/2` access. Derived maps, nested function-head pattern bindings, paths that mix the parameter with another map origin, lenient-only access, and functions with multiple observed shapes remain evidence. Parameter-origin indexing also distinguishes multiple `map()` arguments in one spec, so keys from one input cannot be attributed to another.

`broad_callback_map_contract` requires at least two behaviour implementations to independently consume at least three common literal keys from the same callback parameter. A large shape observed in only one implementation remains evidence because broad callback maps often intentionally permit implementation-specific payloads.

`default_drift` compares literal defaults only for direct maps in one owner module and requires distinct source lines. Different nested maps, distinct computed keys, one atom/string fallback chain, and same-line expression roles remain evidence.

Schema-contract checks join accesses only to the direct value validated by that schema. Wildcard fields, schema fragments composed through module attributes, nested values, and values revalidated against another schema are not undeclared outer fields.

`dual_key_fallback` is grouped by function and map origin and requires at least two distinct returned literal atom/string fallback expression sites. Dynamic compatibility accessors, one-off fallbacks, and a single chain of semantic key aliases remain evidence. A fallback node that can collapse an explicit boolean `false` into a terminal default emits only the higher-confidence `false_collapsing_lookup` finding rather than duplicate normalization advice.

## Parameter-shape entropy

`Reach.Evidence.ParameterShape` groups fixed map shapes flowing into each resolved project parameter. Entropy is the fraction of union keys absent from the intersection: zero means every observed caller supplies the same keys, while one means no key is universal. `parameter_shape_entropy` requires multiple distinct callers and variants, a domain-role parameter, at least two keys consumed by the callee, at least one strictly consumed key that varies between shapes, and configurable minimum union size and entropy. Defensive `Map.get`/bracket access, function-head map patterns, literal companion-argument dispatch, and explicit clause or guarded map/struct dispatch remain evidence-only.

Options/config/external/transport parameter names remain evidence-only. Explicit multi-clause map dispatch and common literal variant tags such as `:type`, `:kind`, or `:status` are treated as intentional unions. Lineage follows only maps that are the whole argument through variables/assignments; it stops at calls and containers to avoid attributing nested metadata maps to an enclosing struct or query.

Changed-code analysis compares the same parameter identity against an old source-only project snapshot. A changed call with fixed-map lineage gates the comparison; entropy increases above `min_entropy_delta` are reported separately and raise aggregate changed risk to medium without rewriting per-function risk.

## Same entity represented as a struct and bare map

`Reach.Evidence.RepresentationOverlap` joins explicit `defstruct` declarations with atom-key bare map constructions in other modules. The raw fact requires at least three shared keys and 0.8 Jaccard key similarity by default. It also records entity-bearing names, nested field-projection sources, presentation/accumulator roles, and direct or caller-level normalization targets.

`same_entity_representation` requires distinctive entity-name evidence and excludes direct or nested projections from the matching entity, adapter/presentation/serialization boundaries, accumulators, explicit `__struct__` maps, function-head patterns, direct struct normalization, helper maps consistently normalized by every caller, structs with explicit map conversion functions, and ambiguous entity names such as `Context`, `Item`, `List`, or `Request`. Findings are grouped by struct/map module pair and name the existing canonical struct instead of suggesting a second abstraction.

## Nil-capable parameters without dominating guards

`nil_parameter_without_guard` requires two independent facts: a literal nil reaches a parameter (or the definition explicitly supplies/accepts nil), and a strict use is reachable without a dominating non-nil proof. Strict uses are limited to field/dynamic receiver access, strict platform map operations, and calls into project functions whose parameter patterns reject nil in every clause. The finding points at the unsafe use while retaining the nil-producing call/default/clause as evidence.

Guard proof uses `Reach.ControlFlow` plus `Reach.Dominator`. Clause-head patterns, `when` guards, `if`/`unless`/`cond` and `case` paths, exhaustive prior nil clauses, matching multi-parameter dispatch, and short-circuit boolean evaluation clear the use. Dominating body normalization and successful `with` bindings stop the original parameter provenance while strict uses in the normalization right-hand side remain visible. Definition-level nil evidence is scoped to one IR definition, default wrappers preserve their exact omitted argument slots, and nil clauses retain their companion patterns and dispatch order. Static module calls are kept separate from dynamic receivers, guard expressions cannot raise, and repeated-variable clauses can consume an exact nil combination before a later clause. Anonymous-function and case-clause bindings that shadow the parameter are not attributed to it. A final wildcard clause is treated as a total nil fallback instead of lending its `_` label to stricter clauses.

Promotion is narrower than raw evidence. Nil defaults remain findings unless the only hazard is a conditional path in a private recursive helper. Nil clauses are promoted when a later broad fallback can be preempted by an earlier strict clause. Literal nil calls are promoted for unconditional broad paths and for literal-gated calls into project functions with a proven non-nil contract; companion-restricted dispatch, comprehensions, parser state, and other path-dependent calls remain evidence.

## Return-shape divergence

`Reach.Evidence.ReturnContract` records terminal return structures per function across clauses and explicit branches. `return_shape_divergence` is intentionally narrower than general union-return analysis: bare/tagged success differences and `:ok` tuple-arity changes remain evidence, but promotion additionally requires a closed direct `@spec` contradicted by the implementation, an unwrapped scalar/struct error beside tagged errors, or a tagged nil/empty sentinel clause beside raw successful values. Nested same-tag structures such as `{:ok, {:ok, value}}` remain evidence because the outer and inner tuples often represent independent transport, callback, parser, scheduler, or storage contracts.

Explicit mixed unions and open project-defined return types establish intent rather than proving a mismatch. Dynamic forwarding, optional success payloads, mode/parser/callback tuples, custom raw error sentinels, implicit `with` fallthrough, conventional error/sentinel alternatives, untagged state-machine tuples, `@impl` callbacks, and source-declared OTP behaviour callbacks suppress promotion. Raising paths do not count as returns, and function-level `else` replaces the successful `try` body when determining terminal shapes.

## Module-level facades

`Reach.Evidence.Facade` aggregates public `defdelegate` declarations and exact same-argument public forwarders by module. `mix reach.check --candidates` emits `:review_facade` only when the forwarded share, minimum public-function count, and target concentration pass named candidate thresholds.

Precision guards exclude modules declared in `boundaries[:public]`, behaviour implementations, modules using framework macros, and deprecated compatibility shims. Public macros count toward the module API even though they are never treated as ordinary forwarders. Documented facades remain advisory at medium confidence; an undocumented module that forwards its entire API to one target may reach high confidence.

The candidate asks maintainers to declare an intentional public boundary or remove a pass-through layer; forwarding is not inherently wrong and is not promoted to a smell.

## Total-function laundering

`Reach.Evidence.TotalFunctionLaundering` records private unary multi-clause parsers whose constrained clauses preserve a literal domain while a final catch-all returns one accepted value. Domain preservation includes identity clauses and equivalent string-to-atom mappings. The fallback must appear in the observed output domain or in a same-named literal `@type`/`@typep` domain.

Smell promotion is narrower. If the fallback has its own explicit accepted-input clause, the catch-all establishes an intentional default normalizer and remains evidence-only. `total_function_laundering` is emitted when the fallback is established only by a same-named declared type and cannot be selected through an explicit domain clause, making malformed input indistinguishable from an otherwise buried accepted value.

Other precision guards exclude public APIs, one-clause domains, transformations such as `inspect(value)`, presentation mappings, mixed semantic mappings, dynamic fallback bodies, and constants outside the established domain. The finding points at the catch-all and asks callers to supply an explicit default or the parser to raise/return an error for unsupported input.

## Source-suppression ratchet

`Reach.Source.Suppression` parses `reach:disable`, `reach:disable-next-line`, and `reach:disable-for-this-file` directives into scope, sorted tokens, source/target lines, and an optional justification following ` -- `. The smell suppression filter consumes the same representation, so reporting and enforcement cannot drift apart.

`Reach.Check.Changed.SuppressionRatchet` compares directive multisets across old/new changed-file snapshots. Stable identities exclude line numbers, preventing a moved unchanged comment from appearing new. Added and removed directives must occur on their corresponding changed hunk side. Added reasonless directives raise aggregate changed-code risk to at least medium; reasoned additions remain visible but do not alter risk.

`mix reach.map` reports project-wide source-suppression and reasonless-suppression counts. This is inventory rather than smell policy: justified suppressions still count, so gradual growth remains observable.

## Fact displacement in changed code

`Reach.Check.Changed.Displacement` builds parse-only old and new snapshots for changed Elixir files and compares location-independent evidence fingerprints. The initial families are atom/string dual-key contracts, conflicting literal-default sets, and ExDNA exact Type-I whole-function clones. Clone fingerprints are encoded as stable hexadecimal hashes at the evidence boundary.

A fact is `:displaced` only when the same fingerprint exists before and after, an old occurrence lies on an old-side changed line, a different new occurrence lies on a new-side changed line, and the total occurrence count did not decrease. Unchanged evidence shifted by an insertion is therefore ignored. Resolved facts and partially reduced facts are not classified as displacement.

## Access-strictness downgrades

`mix reach.check --changed` compares old and new Sourceror ASTs within corresponding diff hunks. `Reach.Check.Changed.AccessStrictness` reports contract erosion when `value.field`, `Map.fetch!/2`, or a required map pattern becomes `Map.get/2,3` for the same function parameter/local variable and literal key. Detection requires strict-access counts to decrease and lenient-access counts to increase, preventing an added optional read from being mistaken for a replacement.

The finding is keyed by module/function/arity, parameter identity (or local variable), and key. This lets parameter renames survive pairing while unrelated functions and keys remain separate. If a changed parameter has current call sites passing map literals without the required key, the result names those callers and recommends normalizing the producer. Per-function risk remains unchanged; an erosion event raises aggregate changed-code risk to at least medium.

Analysis is diff-only and parse-only: old source comes from the merge-base revision, current source from the working tree, and neither revision is compiled or loaded.

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

## JSON/Jason

Jason-specific hand-roll detection belongs in `Reach.Plugins.Jason`, not generic standard-library heuristics. JSON policy stays plugin-owned and dependency-gated.
