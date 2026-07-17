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

## Dependency capability bypass

`Reach.Evidence.Bypass` normalizes standard-library, plugin-pattern, and project-to-dependency clone facts. With `clone_analysis[:include_deps]` enabled, ExDNA reads direct dependency `lib/` sources and retains only clone families spanning project and dependency origins.

Calibration notes:

- An exact-clone pass over Incant, LLM Proxy, Exograph, Phoenix Replay, Host Kit, Gatehouse, JsonCodec, and RustQ produced two facts across eight projects with analyzable local dependencies.
- Both facts identified Exograph copies of `ExAST.Ident` functionality while ExAST was already a direct dependency; manual review confirmed the shared implementation shape.
- Exact ExDNA Type-I clones are promoted to advisory `:reuse_dependency` candidates.
- Type-II/Type-III or lower-similarity matches remain evidence-only pending broader calibration.
- Candidates require review of the dependency's supported public API; Reach must not recommend calling copied internal functions solely because source matches.

## Project clone consolidation

Exact ExDNA Type-I families containing at least two distinct whole project functions can produce advisory `:consolidate_clone` candidates. Reach requires the matched ExDNA fragment to be a complete `def`/`defp`, rather than an identical expression embedded in otherwise different functions. It also excludes behaviour- and `use`-owned modules, where matching callbacks commonly represent intentional parallel implementations.

Reach ranks each function deterministically by module stability and efferent coupling, then by evidence completeness, direct callers, and source location. The selected function is a review target, not a behavioral-equivalence claim. Type-II/Type-III families remain evidence-only. Candidates list every sibling implementation and require maintainers to compare return contracts, errors, effects, and tests before moving callers. Public entrypoints may remain as thin adapters when they preserve an intentional API boundary.

Calibration across thirteen local projects reduced forty-four initial Type-I candidates to one after requiring whole functions and excluding framework/behaviour ownership. The retained candidate was a duplicated private integer-configuration helper in Plausible's analytics and Oban DuckDB modules. The rejected set was dominated by matching expressions inside unrelated functions and intentional callback implementations in Ecto and Oban. A separate pass over the eight checksum-pinned Hex corpus packages produced no candidates.

## Regex parsing of structured formats

`mix reach.trace --pattern regex-on-structured` uses the project data-flow graph rather than source proximity. Its primary route starts at `File.read/1`, `File.read!/1`, or `File.stream!/1,3` with a static `.xml`, `.html`, `.htm`, `.heex`, `.eex`, `.ex`, `.exs`, or `.rs` path and ends at Regex APIs, regex `=~`, or regex-based `String.split`. A fallback accepts dynamic paths only when the sink contains a structure-shaped regex literal such as an XML/HTML tag, `defmodule`, `defstruct`, or `fn\\s`.

Calibration notes:

- A source-only pass over fifteen local projects produced no paths, avoiding nearby-but-unconnected File/Regex false positives.
- A targeted pass over NimbleHQ's Elixir Templates found one intended path: `File.read!("mix.exs")` flowing into `~r/defmodule (.*) do/ |> Regex.run(...)`.
- GitHub structural samples found additional direct regex reads/rewrites of `mix.exs`, validating that the behavior exists in real packages.
- The preset remains a trace workflow rather than a smell. Promotion requires broader path review and explicit suppression policy for intentional release/build scripts.

## Decoded external data crossing boundaries

`Reach.Evidence.ExternalDataBoundary` tracks plugin-owned decoder results into generic storage and process boundaries without compiling source. Jason and Poison own their decode call shapes; the generic provider owns `:persistent_term`, ETS, process dictionaries, sends, GenServer calls/starts, and GenServer callback state returns. Explicit struct/map construction and transformation calls stop provenance.

Raw boundary crossings are evidence. Promotion to the high-confidence `decoded_boundary_leakage` smell additionally requires at least two distinct downstream literal map keys in the same module. This preserves intentionally dynamic stores while finding decoded fixed-shape contracts that lose provenance before consumers apply string-key defaults.

The same fixed-contract evidence produces advisory `introduce_boundary_contract` candidates. Each candidate names the decoder and exact storage/process boundary, emits a draft `@enforce_keys`/`defstruct` when keys are valid fields (otherwise a validation-schema draft), and computes a bounded blast radius from the boundary and literal-key consumer functions through the shared `Reach.Evidence.Impact` traversal also used by `Reach.Inspect.Impact`.

Calibration notes:

- The historical LLM Proxy pricing specimen at `c374082~1` produces one finding and one contract candidate at `lib/llm_proxy/pricing.ex:22`: `Jason.decode!/1` flows into `:persistent_term.put/2`, followed by `cache_read`, `cache_write`, `input`, and `output` consumers. The candidate drafts those four enforced struct fields and names `init/0` plus `calculate_cost/3` in its isolated-source blast radius. The normalized struct-based revision is clean.
- Thirteen current local projects and the eight checksum-pinned Hex packages produce no findings or boundary-contract candidates.
- Exograph structural search for `Poison.decode!(_)` returned a capped 100 candidates across 47 packages. A deterministic 25-package source sample produced one raw evidence fact in `country_data`, whose intentionally dynamic-key GenServer store remains evidence-only after the literal-consumer discriminator; no sampled package produced a smell.

## Nil-capable parameters without dominating guards

`nil_parameter_without_guard` requires two independent facts: a literal nil reaches a parameter (or the definition explicitly supplies/accepts nil), and a strict use is reachable without a dominating non-nil proof. Strict uses are limited to field/dynamic receiver access, strict platform map operations, and calls into project functions whose parameter patterns reject nil in every clause. The finding points at the unsafe use while retaining the nil-producing call/default/clause as evidence.

Guard proof uses `Reach.ControlFlow` plus `Reach.Dominator`. Clause-head patterns, `when` guards, positive and reversed `if` checks, exhaustive prior nil clauses, matching multi-parameter dispatch, and short-circuit boolean evaluation clear the use. Definition-level nil evidence is scoped to one IR definition, and nil clauses retain their other patterns; these two constraints avoid conditional-compilation and unrelated-dispatch false positives. Anonymous-function and case-clause bindings that shadow the parameter are not attributed to it.

Calibration notes:

- The first broad pass produced twenty-four findings across thirteen source corpora. Every one was intentional: matching multi-parameter nil dispatch, callback-variable shadowing, short-circuit receiver guards, or conditional-compilation definitions.
- Context-sensitive nil sources, pattern coverage, lexical binding isolation, short-circuit proof, and source-path feasibility reduced the same corpus to one reviewed finding: `Plausible.Teams.Billing.monthly_pageview_usage(nil, _)` calls `usage_cycle(nil, ...)`, which preloads nil and then reads `team.subscription`.
- The eight checksum-pinned Hex packages produce zero findings.
- The historical LLM Proxy `07ed32b~1` response-handler source produces both intended findings when the two nil calls from the regression specimen are included: the two- and three-argument handlers pass nil to the struct-restricted token-pool function. Revision `07ed32b` is clean because `not is_nil(token)` moved into the helper clause head.
- Hex-wide `_(nil)` prefilters by argument position were registered for arities one through three. The live Exograph structural endpoint returned HTTP 500 during the 2026-07-13 calibration, so no unsupported prevalence count is claimed.

## Return-shape divergence

`Reach.Evidence.ReturnContract` records terminal return structures per function across clauses and explicit branches. `return_shape_divergence` is intentionally narrower than general union-return analysis: it reports only conflicts around the success tag—bare `:ok` versus tagged `{:ok, value}`, tagged success mixed with a known raw value, or multiple arities for the `:ok` tag. `nested_return_tag` separately reports duplicate success wrappers such as `{:ok, {:ok, value}}`.

Dynamic forwarding, implicit `with` fallthrough, conventional error/sentinel alternatives, untagged state-machine tuples, and `@impl` callbacks suppress promotion. Raising paths do not count as returns, and function-level `else` replaces the successful `try` body when determining terminal shapes.

Calibration notes:

- The broad prototype produced seventy-three findings across thirteen source corpora, dominated by intentional compiler state tuples, callback returns, rich error tuples, and transformed `try` values.
- Restricting policy to `:ok`, excluding untagged tuples and dynamic outcomes, honoring `@impl`, and fixing `try`/`else` semantics reduced the same corpus to one reviewed finding: Elixir's private `Mix.Utils.do_symlink_or_copy/3` returns bare `:ok` after linking but `{:ok, files}` after copying.
- The eight checksum-pinned Hex packages produce no findings. No corpus project produced a nested-success-tag finding.

## Module-level facades

`Reach.Evidence.Facade` aggregates public `defdelegate` declarations and exact same-argument public forwarders by module. `mix reach.check --candidates` emits `:review_facade` only when the forwarded share, minimum public-function count, and target concentration pass named candidate thresholds.

Precision guards exclude modules declared in `boundaries[:public]`, behaviour implementations, modules using framework macros, and deprecated compatibility shims. Public macros count toward the module API even though they are never treated as ordinary forwarders. Documented facades remain advisory at medium confidence; an undocumented module that forwards its entire API to one target may reach high confidence.

Calibration notes:

- A source-only pass over fifteen local projects initially found ten candidates, exposing intentional routers, behaviour adapters, compatibility shims, and macro-heavy public APIs as important false-positive classes.
- After adding the semantic guards above, the same pass produced three candidates: one undocumented internal Exograph wrapper at high confidence and two documented HostKit runtime facades at medium confidence.
- The candidate asks maintainers to declare an intentional public boundary or remove a pass-through layer; it does not claim that forwarding is inherently wrong and is not promoted to a smell.

## Total-function laundering

`Reach.Smell.Checks.TotalFunctionLaundering` detects private unary multi-clause parsers whose constrained clauses preserve a literal domain while a final catch-all silently returns one accepted value. Domain preservation includes identity clauses and equivalent string-to-atom mappings. The fallback must appear in the observed output domain or in a same-named literal `@type`/`@typep` domain.

Precision guards exclude public APIs, one-clause domains, transformations such as `inspect(value)`, presentation mappings, mixed semantic mappings, dynamic fallback bodies, and constants outside the established domain. The finding points at the catch-all and asks callers to supply an explicit default or the parser to raise/return an error for unsupported input.

Calibration notes:

- The historical LLM Proxy `Catalog.Model` burial specimen is detected at `routing_strategy(_strategy) -> :ordered`; `:ordered` is established by the `routing_strategy` type even though the earlier clauses omitted it.
- Incant's `external_value/1` serializer remains clean because its catch-all transforms the input with `inspect/1`.
- An initial Exograph structural prefilter (`_ when _ in [_, _]`) returned twenty sampled fragments across five package versions, all from vendored dependency paths; it is useful only as a broad candidate query, not as the rule itself.
- A source-only pass over thirteen local projects initially found four intentional display/log-level defaults. Requiring every constrained clause to preserve the logical domain removed all four while retaining the LLM Proxy specimen.
- The eight checksum-pinned Hex corpus packages produce no findings.

## Source-suppression ratchet

`Reach.Source.Suppression` parses `reach:disable`, `reach:disable-next-line`, and `reach:disable-for-this-file` directives into scope, sorted tokens, source/target lines, and an optional justification following ` -- `. The smell suppression filter consumes the same representation, so reporting and enforcement cannot drift apart.

`Reach.Check.Changed.SuppressionRatchet` compares directive multisets across old/new changed-file snapshots. Stable identities exclude line numbers, preventing a moved unchanged comment from appearing new. Added and removed directives must occur on their corresponding changed hunk side. Added reasonless directives raise aggregate changed-code risk to at least medium; reasoned additions remain visible but do not alter risk.

`mix reach.map` reports project-wide source-suppression and reasonless-suppression counts. This is inventory rather than smell policy: justified suppressions still count, so gradual growth remains observable.

Calibration across thirteen local projects found one existing source suppression, a reasonless `bare_rescue` file suppression in HostKit. Historical search found its introduction in commit `031cdc1`, and the changed-code ratchet classifies that exact addition as reasonless. The eight checksum-pinned Hex corpus packages contain no Reach source suppressions.

## Fact displacement in changed code

`Reach.Check.Changed.Displacement` builds parse-only old and new snapshots for changed Elixir files and compares location-independent evidence fingerprints. The initial families are atom/string dual-key contracts, conflicting literal-default sets, and ExDNA exact Type-I whole-function clones. Clone fingerprints are encoded as stable hexadecimal hashes at the evidence boundary.

A fact is `:displaced` only when the same fingerprint exists before and after, an old occurrence lies on an old-side changed line, a different new occurrence lies on a new-side changed line, and the total occurrence count did not decrease. Unchanged evidence shifted by an insertion is therefore ignored. Resolved facts and partially reduced facts are not classified as displacement.

Calibration notes:

- Synthetic burial fixtures move dual-key access and conflicting defaults into private helpers while preserving occurrence counts; both remain visible as displaced evidence.
- Exact-clone fixtures retain two whole-function copies while relocating one implementation; expression-level clone fragments remain excluded.
- A scan over 199 Incant commits and 174 recent commits across Exograph, HostKit, LLM Proxy, Plausible, Hologram, and Volt produced no displacement findings.
- Snapshot projects exposed a clone-cache collision when different projects reused identical node-id ranges. Clone caching now keys on the project's unique cache key, with a content-sensitive fallback for manually constructed projects.

## Access-strictness downgrades

`mix reach.check --changed` compares old and new Sourceror ASTs within corresponding diff hunks. `Reach.Check.Changed.AccessStrictness` reports contract erosion when `value.field`, `Map.fetch!/2`, or a required map pattern becomes `Map.get/2,3` for the same function parameter/local variable and literal key. Detection requires strict-access counts to decrease and lenient-access counts to increase, preventing an added optional read from being mistaken for a replacement.

The finding is keyed by module/function/arity, parameter identity (or local variable), and key. This lets parameter renames survive pairing while unrelated functions and keys remain separate. If a changed parameter has current call sites passing map literals without the required key, the result names those callers and recommends normalizing the producer. Per-function risk remains unchanged; an erosion event raises aggregate changed-code risk to at least medium.

Calibration notes:

- Incant commit `c0cf146` is the positive specimen: three `table_state.field` reads became `Map.get` calls after a caller passed `%{}`. Reach reports all three at lines 72–74.
- Scanning 199 Incant commits found only those three intended events in that commit.
- Scanning 174 recent commits across Exograph, HostKit, LLM Proxy, Plausible, Hologram, and Volt produced no findings.
- Analysis is diff-only and parse-only: old source comes from the merge-base revision, current source from the working tree, and neither revision is compiled or loaded.

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
