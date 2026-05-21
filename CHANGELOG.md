# Changelog

## Unreleased

### New

- **Architecture layer ergonomics** — `.reach.exs` now validates unknown layer references, supports allowlist-style dependency policy, dependency exceptions, optional layer coverage checks, and layer-cycle violations with concrete call-edge witnesses.

### Changed

- **Evidence provider namespace** — moved clone analysis under `Reach.Evidence.CloneAnalysis` and introduced `Reach.Evidence` as the namespace for reusable facts consumed by smells, checks, and refactoring candidates.
- **Jason plugin smell** — added an evidence-backed smell check for hand-rolled JSON sanitizers, encoders, and simple `Jason.Encoder` implementations that should use Jason protocol support directly.
- **Standard library bypass smell** — added conservative Path/URI checks for hand-written basename, extension, URL, and query-string splitting, plus higher-context `Enum.map`→flatten, order-safe reduce/reverse `Enum.flat_map`, paired `Map.has_key?`/`Map.put` update, `Map.update!`, and reduce-based `Enum.frequencies` heuristics.
- **Map contract evidence** — added `Reach.Evidence.MapContract` as a reusable evidence provider for maps that are created with a fixed shape, returned from local functions, and then read/updated as implicit contracts.
- **Map contract candidates** — `mix reach.check --candidates` now reports advisory struct, boundary, or typed-map contract candidates when repeated implicit map contracts appear in project source.
- **Poison plugin rename** — split the Poison effect classifier into `Reach.Plugins.Poison` now that Jason has its own plugin.
- **Evidence corpus scanner** — added `scripts/evidence_corpus_scan.exs` for focused Jason, standard-library bypass, and map-contract evidence scans across repositories, backed by lightweight `family/0` and `kinds/0` evidence provider metadata.
- **Plugin evidence refinement** — added a generic `refine_evidence/2` plugin hook so dependency plugins can annotate reusable evidence without owning smell or candidate policy; Jason now classifies maps passed to `Jason.encode/1,2` or `Jason.encode!/1,2` as external payload contracts.
- **Corpus-tuned evidence** — tightened evidence scanning after reviewing Hex corpus hits, including safe handling for dynamic aliases and avoiding `Enum.flat_map/2` suggestions for reduce callbacks shaped like `acc ++ [expr]`.

### Fixed

- **Root task help** — `mix reach --help` now prints usage information instead of generating the default HTML report.
- **Protocol and macro-heavy visualizations** — Elixir frontend now attaches `defimpl`/`defprotocol` functions and nested modules to their real module names, including multi-part nested `defmodule` names, and treats quoted macro-generated definitions as data while preserving `unquote` references. This removes bogus `(top-level)` graph buckets and repeated garbage nodes in reports for macro-heavy projects.
- **Redundant computation false positives** — stateful IR counter calls are no longer reported as duplicate pure computations during Reach's own strict smell checks.

## 2.5.0

### New

- **Trivial delegate smell check** — added conservative detection for pass-through `defdelegate` calls and hand-written same-argument forwarding functions, including alias, Erlang module, and static generated delegate targets while allowing documented facades, behaviour adapters, semantic aliases, and ambiguous local calls.
- **Conversion idiom smell checks** — added conservative checks for identity float arithmetic and one-shot `List.to_tuple/1` + `elem/2` access.

### Fixed

- **Phoenix/Ecto dead-code false positives** — `--dead-code` no longer reports compile-time DSL macros such as `Phoenix.Component.attr/3`, `slot/3`, Phoenix router macros, Ecto schema fields, or migration table/column declarations as unused results.
- **Corpus scan robustness** — `scripts/smell_corpus_scan.exs` now reports per-repository exits as scan errors instead of aborting the whole corpus run, and selected-kind filtering handles source smell metadata.
- **Pipe-shaped macro heads** — the Elixir frontend no longer crashes on unusual macro heads that use `|>` as a user-defined operator pattern.

## 2.4.0

### New

- **Framework smell checks** — added plugin-provided Phoenix, Ecto, and Oban smell checks for LiveView lifecycle mistakes, Ecto query pitfalls, unsafe SQL interpolation, money-like `:float` fields, and Oban argument shape issues.
- **Security/source smell checks** — added checks for unsafe dynamic atom creation, unsafe `:erlang.binary_to_term/1`, missing `@external_resource` declarations, and conservative Ecto query pinning/cross-join issues.
- **Custom/plugin smell infrastructure** — projects can provide custom smell modules via `.reach.exs`, and framework plugins can register smell checks through `Reach.Plugin.smell_checks/0`.
- **Smell corpus tooling** — added `scripts/smell_corpus_scan.exs` for repeatable scans across external repositories with plugin and kind filters.
- **Smell profiling tooling** — added `scripts/profile_smells.exs` for per-check, per-pattern, and per-query profiling against the current project or an external repo.

### Changed

- **Source smell DSL rename** — source-level smell checks now use `Reach.Smell.Check.Source` instead of `Reach.Smell.Check.Pattern`. The unified `smell/4` DSL also supports AST callback rules with `mode: :ast` for hot source-shape checks that need custom matching.
- **Pattern smell performance** — source smell checks infer source prefilters from ExAST selectors, share prefilter normalization through `Reach.Smell.PatternConfig`, and route combined pattern/AST callback rules through `Reach.Smell.SourceRunner`.
- **Smell performance** — optimized pattern scanning, source AST caching, CLI command tests, architecture policy tests, and the `IdiomMismatch` smell check to reduce repeated full-project/file traversals.
- **Pattern smell consolidation** — consolidated hot ExAST selectors for boolean `case` and boolean `Map.put/3` tracking; the boolean `case` smell now uses the unified source DSL's AST callback mode.

### Fixed

- **Plugin smell discovery** — plugin smell modules are no longer accidentally auto-discovered as generic built-ins; plugin checks run only through plugin registration.
- **Real-world false positives** — narrowed noisy Phoenix raw HTML, LiveView `assign_new`, and Oban argument checks based on scans of open-source Elixir projects.
- **Pattern prefilter safety** — inferred prefilters ignore ExAST predicate internals so DSL-style selectors such as Ecto `field(name, :float)` are not skipped incorrectly.

## 2.3.5

### New

- **Strict smell gates** — `mix reach.check --smells --strict` now fails when non-baseline smell findings are present. Projects can also enable this with `smells: [strict: true]` in `.reach.exs`.
- **Check baselines** — `mix reach.check` supports `--baseline PATH`, `--write-baseline PATH`, and `checks: [baseline: PATH]` to suppress known architecture/smell findings while failing on new ones.

### Changed

- **Combined checks** — `mix reach.check --arch --smells` now runs all requested check modes and shares one project analysis where possible.
- **Dogfooding** — Reach now runs strict smell checking against itself in CI with tuned smell thresholds and an explicit baseline file.

### Fixed

- **Optional JavaScript support** — compiling Reach without QuickBEAM no longer emits warnings about the unavailable JavaScript frontend.
- **Self-smells** — fixed actionable smell findings in Reach's own code and prevented pattern smell declarations from flagging themselves.

## 2.3.4

### Fixed

- **Docs publishing** — `mix docs` and `mix hex.publish docs` now run in the `:docs` Mix environment, avoiding dev-only dependency self-conflicts during Hex docs publishing.

## 2.3.3

### New

- **Semantic idiom smells** — detects double map lookups, sentinel `Map.get/3` defaults, length-based list indexing, invalid integer `Keyword` keys, and missing `Logger` imports.
- **More collection idioms** — detects sort-then-reverse, sort-then-index, and `Enum.take_while/2` followed by counting.

### Changed

- **Dependencies** — refreshed Hex dependencies, including Volt 0.10.x.

### Fixed

- **Smell false positives** — tightened keyword-default and Logger detection based on Hex package scans.
- **Nested Mix tests** — run the ProgramFacts stress script under `MIX_ENV=test` to avoid dev-only dependency self-conflicts.

## 2.3.2

### New

- **Case-on-boolean** — flags `case expr do true -> ...; false -> ... end` when the subject is a comparison or boolean operator. Uses ExAST capture guards to avoid false positives on sentinel pattern matches.
- **Case to match?** — flags `case _ do pat -> true; _ -> false end`; suggests `match?/2`.
- **Needless bool** — flags `if cond, do: true, else: false` and the inverse.
- **Manual max/min** — flags `if a > b, do: a, else: b` using ExAST repeated-variable matching; suggests `Kernel.max/2` or `Kernel.min/2`.
- **`@doc false` on `defp`** — flags redundant `@doc false` before private functions.
- **Sort then negative take** — flags `Enum.sort |> Enum.take(-n)`; suggests `Enum.sort(:desc) |> Enum.take(n)`.
- **Cond two-clause** — flags `cond do ... true -> ... end` with exactly two clauses; suggests `if/else`.
- **Unless/else** — flags `unless ... else ...`; suggests `if` with positive case first.
- **Redundant assignment** — flags `result = expr; result` where the binding is immediately returned.
- **Redundant nil default** — flags `Keyword.get(_, _, nil)` and `Map.get(_, _, nil)`.
- **Split then head** — flags `String.split(s, sep) |> hd/List.first`; suggests `parts: 2`.
- **Filter then first** — flags `Enum.filter |> List.first/hd`; suggests `Enum.find/2`.
- **Map.new / MapSet.new** — flags `Enum.map |> Enum.into(%{})`, `Enum.into(_, %{})`, `Enum.into(_, MapSet.new())`, `Enum.map |> Enum.concat`.

### Fixed

- **`++` in reduce false positives** — the check now verifies that an operand of `++` actually references the reduce accumulator variable.
- **Dogfooding** — fixed all actionable smell findings in Reach's own code across 15 files.
- **CI** — `mix ci` now runs `reach.check --arch --smells`.
- **Credo overlap documented** in README.

### Changed

- **ex_ast** bumped to `~> 0.11.2`.

## 2.3.1

### New

- **Case-on-boolean detection** — flags `case expr do true -> ...; false -> ... end` when the subject is a comparison or boolean operator. Uses ExAST capture guards to avoid false positives on sentinel pattern matches like `case func() do false -> ... end`.
- **Cond two-clause detection** — flags `cond do ... true -> ... end` with exactly two clauses; suggests `if/else`.
- **Unless/else detection** — flags `unless ... else ...`; suggests `if` with the positive case first.
- **Redundant assignment** — flags `result = expr; result` where the binding is immediately returned.
- **Manual max/min** — flags `if a > b, do: a, else: b` using ExAST repeated-variable matching; suggests `Kernel.max/2` or `Kernel.min/2`.
- **`@doc false` on `defp`** — flags redundant `@doc false` before private functions (uses ExAST 0.11.2 wildcard function name matching).
- **Sort then negative take** — flags `Enum.sort |> Enum.take(-n)`; suggests `Enum.sort(:desc) |> Enum.take(n)`.

### Fixed

- **`++` in reduce false positives** — the check now verifies that an operand of `++` actually references the reduce accumulator variable. Previously any `++` inside a reduce callback was flagged, including one-shot concats of two derived lists. Eliminates 17 false positives across the top 200 Hex packages.
- **Dogfooding** — ran `reach.check --smells` against Reach's own codebase and fixed all actionable findings across 15 files.
- **CI** — `mix ci` now runs `reach.check --arch --smells` (was `--arch` only).

### Changed

- **ex_ast** bumped to `~> 0.11.2` for wildcard function name matching in `def`/`defp` patterns.

## 2.3.0

### New

- **Repeated traversal detection** — flags the same variable traversed by 2+ different `Enum` functions (e.g. `Enum.max(list)` + `Enum.min(list)` + `Enum.count(list)`); suggests combining into a single `Enum.reduce/3`.
- **Nested enum detection** — flags `Enum.member?/2` nested inside another `Enum` traversal of the same variable (O(n²)); suggests precomputing a `MapSet`.
- **Multiple Enum.at detection** — flags 3+ `Enum.at/2` calls on the same variable with literal indices; suggests pattern matching.
- **Append in recursion** — flags `++ [item]` in recursive tail calls (O(n²)); suggests prepend with `[item | acc]` and `Enum.reverse/1` in the base case.
- **Piped Regex.replace** — flags `text |> Regex.replace(~r/.../, "")` where the pipe injects the string as the regex argument; suggests `String.replace/3`. Uses the new ExAST `piped()` predicate to avoid false positives on direct `Regex.replace/3` calls.
- **More Map.keys/values patterns** — `Map.keys |> Enum.join`, `Map.keys |> Enum.uniq` (redundant), `Map.keys/values |> Enum.count/length` (use `map_size/1`), `Map.keys |> Enum.member?` (use `Map.has_key?/2`), `Map.values |> Enum.sum/max/min/join`.
- **More pipeline waste** — `List.foldr/3`, `Enum.min_by/max_by/dedup_by` with identity function, `Enum.filter |> Enum.filter`, `Enum.map |> Enum.flat_map/List.flatten`, `Enum.sort/2 |> Enum.reverse`, `Enum.with_index |> Enum.reduce`, redundant `Enum.map_join` empty separator.
- **More collection idioms** — `Integer.to_string |> String.graphemes` (use `Integer.digits`), `length(String.split) - 1` (Python count idiom), `Enum.at(list, -1)` (use `List.last/1`).
- **Parser warning suppression** — `Code.string_to_quoted` calls now pass `emit_warnings: false` so reparsing dependency source files no longer emits tokenizer/parser warnings.

### Changed

- **ex_ast** bumped to `~> 0.11.1` for the `piped()` selector predicate.

### Fixed

- **Smell false positives** — IR-based checks (repeated traversal, multiple Enum.at) now scope per-clause to avoid false positives from multi-clause functions. Corpus-tested against 200 top Hex packages: 0 crashes, 0 false positives.

## 2.2.0

### New

- **Length comparisons** — flags `length(list) == 0`, `0 == length(list)`, and `length(list) > 0`; suggests list pattern matching, `== []`, or `!= []`.
- **Identity `Enum.uniq_by/2`** — flags `Enum.uniq_by(collection, fn x -> x end)`; suggests `Enum.uniq/1`.
- **Identity `Enum.sort_by/2`** — flags `Enum.sort_by(collection, fn x -> x end)`; suggests `Enum.sort/1`.
- **`length/1` in guards** — flags small literal comparisons in guards; suggests list pattern matching.

### Fixed

- **Regression coverage for bare literal `with` clauses** — keeps valid clauses such as `true` in `with` blocks from regressing.
- **CI** — refactored the length-in-guard check to satisfy strict Credo nesting rules.

## 2.1.0

### New

- **Enum.at/2 inside loop** — flags O(n) indexed access inside loops (O(n²) total).
- **List.delete_at/2 inside loop** — same O(n²) concern.
- **Enum.count/1 without predicate** — suggests `length/1` (avoids protocol dispatch).
- **Map.put with variable key and boolean value** — suggests MapSet for membership tracking (excludes atom/string keys to avoid struct field false positives).
- **Map.values → Enum.all?/any?/find/filter/map** — iterate the map directly as `{key, value}` pairs.
- **Enum.map → Enum.max/min/sum** — allocates intermediate list; use `*_by` or reduce.
- **List.foldl/3** — non-idiomatic; use `Enum.reduce/3`.
- **String.graphemes → Enum.reverse → Enum.join** — use `String.reverse/1`.
- **Redundant negated guard** — flags `when x != y` immediately after `when x == y` on the same variables.
- **Destructure then reconstruct** — flags `[a, b, c]` pattern where the body rebuilds the same list.

### Fixed

- **Frontend crash on `import Mod, only: :macros`** — atom values (`:macros`, `:functions`) are now handled correctly instead of crashing with `Enumerable not implemented for Atom`.
- **Frontend crash on macro-generated AST** — bare atoms in `with` clause lists, non-list `else` clauses, and non-list handler clauses no longer crash the parser.
- **CI compatibility** — full `mix ci` runs on Elixir 1.19 only; 1.18 runs compile + tests (formatter output differs between versions).

## 2.0.1

### Fixed

- **ex_ast dependency** — `ex_ast` is now a regular dependency instead of `only: [:dev, :test]`. Pattern smell checks import ExAST at compile time, so the previous declaration made Reach uninstallable from Hex. (Fixes #14)

### Improved

- **Smell false positive reduction** — narrowed loop antipatterns to accumulator loops and recursive operands, excluded compile-time constructs and formatting functions from redundant computation, removed debatable patterns (chained `String.replace`, `Enum.take` with negative count, sequential `Enum.filter`). Validated on 19 Hex packages: 63% fewer findings, all remaining verified as true positives.
- **Module documentation** — all public modules now have `@moduledoc` descriptions.

## 2.0.0

### Breaking changes

- **Canonical CLI surface** - Reach now centers on the new dotted command model:
  - `mix reach.map`
  - `mix reach.inspect TARGET`
  - `mix reach.trace`
  - `mix reach.check`
  - `mix reach.otp`
- **Legacy tasks removed** - old task names now fail fast with exact migration instructions instead of running analysis:
  - `mix reach.modules` → `mix reach.map --modules`
  - `mix reach.coupling` → `mix reach.map --coupling`
  - `mix reach.hotspots` → `mix reach.map --hotspots`
  - `mix reach.depth` → `mix reach.map --depth`
  - `mix reach.effects` → `mix reach.map --effects`
  - `mix reach.boundaries` → `mix reach.map --boundaries`
  - `mix reach.xref` → `mix reach.map --data`
  - `mix reach.deps TARGET` → `mix reach.inspect TARGET --deps`
  - `mix reach.impact TARGET` → `mix reach.inspect TARGET --impact`
  - `mix reach.slice TARGET` → `mix reach.trace TARGET`
  - `mix reach.flow ...` → `mix reach.trace ...`
  - `mix reach.dead_code` → `mix reach.check --dead-code`
  - `mix reach.smell` → `mix reach.check --smells`
  - `mix reach.graph TARGET` → `mix reach.inspect TARGET --graph`
  - `mix reach.concurrency` → `mix reach.otp --concurrency`
- **JSON envelopes changed** - canonical commands now expose canonical `command` fields. Some delegated analysis payloads also include `tool` to identify the internal analysis implementation.
- **Optional boxart dependency bumped** - graph rendering now requires `{:boxart, "~> 0.3.3"}` to pick up Unicode-safe syntax highlighting.

### New

- **`mix reach.map`** - project bird's-eye view with modules, hotspots, coupling/cycles, effects, boundaries, control depth, and data-flow summaries.
- **`mix reach.inspect TARGET`** - consolidated target view for context, dependencies, impact, data, graph rendering, slicing, advisory refactoring candidates, and `--why` relationship explanations.
- **`mix reach.trace`** - canonical entrypoint for taint flow, variable tracing, backward slicing, forward slicing, and slice graphs.
- **`mix reach.check`** - structural checks for architecture policy, changed-code risk, dead code, smells, and advisory candidates.
- **`.reach.exs` architecture policy** with:
  - `layers`
  - `deps[:forbidden]`
  - `source[:forbidden_modules]`
  - `source[:forbidden_files]`
  - `calls[:forbidden]`
  - `effects[:allowed]`
  - `boundaries[:public]`
  - `boundaries[:internal]`
  - `boundaries[:internal_callers]`
  - `risk[:changed]`
  - `candidates[:thresholds]`
  - `candidates[:limits]`
  - `smells[:fixed_shape_map]`
  - `tests[:hints]`
- **Architecture violations** for forbidden dependencies, forbidden modules/files, exact layer cycle components, effect policy, public API boundaries, internal boundaries, and config errors.
- **Changed-risk reports** with changed files, changed functions, aggregate risk, risk reasons, caller impact counts, public API touches, and suggested tests.
- **Graph-backed advisory refactoring candidates**:
  - `introduce_boundary`
  - `isolate_effects`
  - `extract_pure_region`
  - `break_cycle`
- **Candidate metadata** - candidates include `confidence`, `actionability`, `proof`, and cycle `representative_calls` so agents do not treat graph facts as automatic edits.
- **Umbrella source scanning** - Mix project analysis now includes `apps/*/lib/**/*.ex` and `apps/*/src/**/*.erl`.
- **Project dogfood policy** - Reach now ships a root `.reach.exs` and runs `mix reach.check --arch` in CI.

### Improved

- **Canonical implementation structure** - legacy Mix task modules are removed shims; reusable logic moved into `Reach.CLI.Analyses.*` modules used by canonical commands.
- **Canonical JSON consistency** - canonical commands keep canonical `command` values even when using shared internal analyses.
- **Graph rendering reliability** - Reach now relies on boxart `v0.3.3` for Unicode-safe syntax highlighting and no longer sanitizes source snippets locally.
- **Text output polish** - default text output is capped and formatted for readability on large projects, with `--limit N` and `--all` expansion controls for `reach.trace` and `reach.inspect --context`.
- **Large graph UX** - `reach.inspect FILE:LINE --graph` uses a targeted single-file load and summarizes very large CFGs instead of flooding the terminal with huge Boxart output.
- **Taint tracing performance** - `reach.trace --from ... --to ...` computes reachable sinks per source instead of recomputing reachability for every source/sink pair. The Plausible validation case dropped from ~130s to ~3s.
- **ProgramFacts integration** - Reach now uses generated Elixir projects from `program_facts ~> 0.2.0` in test/dev validation for call paths, layouts, data flow, branches, richer syntax fixtures, effects, architecture policies, and advisory candidates.
- **Compiler diagnostics** - BEAM frontend compilation now passes `return_diagnostics: true` and restores compiler debug-info options safely.
- **Effect policy precision** - `:module_def` and `:function_def` classify as pure, so pure-only effect policies do not need to whitelist `:unknown` just for wrapper nodes.
- **Public API policy precision** - public API checks now use the configured public API namespace instead of only the first top-level module segment.
- **Candidate precision** - expected callback/effect-boundary shapes are suppressed for effect-isolation candidates, `:unknown` and `:exception` no longer inflate mixed-effect candidates, and cycles prefer minimal representative evidence.
- **Changed deletion handling** - deletion-only hunks are no longer attributed to a synthetic current-file line.
- **Inspect data returns** - `reach.inspect --data` now summarizes clause final expressions rather than direct clause nodes.
- **Loose map contract detection** - `reach.check --smells` now flags same-variable atom/string key fallback patterns such as `metadata["id"] || metadata[:id]`, a common sign that a map should be normalized once or replaced with a struct/explicit contract. Smell checks are now structured as individual checks behind a small behaviour.
- **Repeated map shape detection** - `reach.check --smells` flags repeated atom-key map literals with the same shape as possible struct/contract candidates.
- **Clone-backed structural consistency** - optional clone analysis evidence now enriches smell checks so Reach can flag return-contract drift, side-effect ordering drift, map-contract drift, validation drift, and higher-confidence behaviour candidates across similar code.
- **Plugin-owned framework semantics** - framework-specific trace presets, behaviour labels, and visualization edge filtering now live behind plugin callbacks instead of generic trace/map/visualization modules.
- **Changed clone-family warnings** - `mix reach.check --changed` now reports similar cloned sibling functions so partial fixes are easier to spot and test.
- **Stronger ProgramFacts fuzzing** - oracle validation now covers all generated policies at boundary sizes, metamorphic transform sequences that preserve declared facts, feedback-directed samples across canonical and target-based JSON commands, visualization block invariants, clone-backed smell checks, and a replayable stress script with saved failure corpora.
- **Behaviour candidate detection** - `reach.check --smells` flags groups of modules exposing the same public callback set as possible behaviour extraction candidates.
- **Compile-time vs runtime config detection** - `reach.check --smells` flags `Application.get_env`/`fetch_env` captured in module attributes and `Application.compile_env` used inside runtime functions.
- **ExAST-backed pattern smell DSL** — `use Reach.Smell.PatternCheck` with `smell ~p[...]` macro for declarative source-pattern detection. Pipes, operators, function calls, and module attributes all work with the `~p` sigil. Guarded patterns use `from(~p[...]) |> where(...)`. Pattern checks share a zipper cache across modules.
- **Collection and idiom smells** — `reach.check --smells` now detects `Enum.reverse |> hd`, `Enum.reverse ++ tail`, `inspect |> String.starts_with?`, chained `String.replace`, `Map.keys |> Enum.map`, `List.to_tuple |> elem`, redundant `Enum.join("")`, negative `Enum.take`, `String.graphemes |> length`, `String.length == 1`, `Integer.to_string |> String.to_charlist`, and anonymous fn applied with `.()` in pipes.
- **Pipeline waste smells** — detects `Enum.reverse |> Enum.reverse`, `Enum.filter |> Enum.count`, `Enum.map |> Enum.count`, `Enum.filter |> Enum.filter`, `Enum.sort |> Enum.take/reverse/at`, `Enum.drop |> Enum.take`, `Enum.take_while |> count/length`, and `Enum.map |> Enum.join`.
- **Loop antipattern smells** — `++` inside loop (O(n²)), `<>` inside loop (O(n²)), manual min/max/sum reduce, and manual frequency counting with `Map.update`.
- **Idiom mismatch smells** — guard equality where pattern match suffices, `Map.update` then `Map.get/fetch` on same variable.

### Documentation

- Added the configuration guide for `.reach.exs` policy configuration.
- Added `examples/reach.exs` as a starting architecture policy.

### Validation

- Full CI passes: format, JS checks, Credo strict, ExDNA, architecture policy, Dialyzer, and ExUnit.
- Canonical command validation passed across 20 real codebases and every canonical submode, including graph modes and removed-command behavior.

## 1.8.0

### New

- **gen_statem support** - `mix reach.otp` detects and analyzes gen_statem
  state machines with both callback modes:
  - `:state_functions` - states extracted from public arity-3 functions
    (e.g. `def connected(:cast, ..., data)`) with return value validation
  - `:handle_event_function` - states extracted from `handle_event/4`
    clause patterns, with module attribute resolution (`@state :active`)
  - Extracts initial state(s), state transition graph, and event types
    per state (cast, call, info, internal, timeout)
  - Tested against Redix, Postgrex, and Livebook

- **Dead GenServer reply detection** - finds `GenServer.call` sites where
  the reply value is discarded. These calls could use `GenServer.cast`
  instead, or the handler could return a cheaper reply. Deduplicates
  findings from multi-clause function expansion.

- **Cross-process coupling analysis** - detects hidden data dependencies
  across process boundaries:
  - Builds per-module effect summaries (ETS tables read/written, process
    dictionary keys, send targets)
  - At `GenServer.call/cast` sites, flags when caller and callee share
    ETS tables or process dictionary keys
  - Reports conflict type: `callee_writes` or `callee_reads_caller_write`

- **Supervision tree extraction** - `mix reach.otp` finds
  `Supervisor.start_link(children, opts)` calls, resolves children variable
  references to their list definitions, and extracts child module names
  from `__aliases__` AST nodes.

### Improved

- **Smell detection false positives fixed** - pattern cons operator (`|`),
  string interpolation `to_string`, and unrelated `Enum.map`/`List.first`
  pairs no longer produce false findings. Eager pattern detection now
  requires actual data flow connection, not just line proximity. Same-line
  pipes sort by column for correct pairing.

- **OTP analysis performance** - precompute shared `all_nodes` across
  sub-analyses, replace O(n2) `find_enclosing_module` with O(1) index
  lookup. ~1000× speedup on the OTP-specific analysis for large codebases.

- **Refactored OTP analysis into submodules** - GenServer, GenStatem,
  Coupling, DeadReply, CrossProcess under `Reach.OTP.*`.

- **Self-healing** - ran Reach on itself, fixed 9 redundant computations
  and 1 dead code finding in its own source.

## 1.7.0

### New

- **JavaScript frontend** - parse JS/TS source files into Reach IR via
  QuickBEAM bytecode disassembly. Handles function definitions, variables,
  closures, binary/unary operators, method calls, object literals, control
  flow, and async/await. TypeScript is stripped via OXC, ES module syntax
  (`export`/`import`) is removed via OXC AST patching. Only available when
  `:quickbeam` is installed (`{:quickbeam, "~> 0.10", optional: true}`).

- **QuickBEAM plugin** - cross-language analysis for Elixir + JavaScript
  projects using QuickBEAM. Detects `QuickBEAM.eval(rt, "js source")` calls
  with string literals, parses the embedded JS, and injects function nodes
  into the graph. Creates three edge types:
  - `:js_eval` - Elixir eval call → JS function definitions
  - `{:js_call, name}` - `QuickBEAM.call(rt, "name")` → JS named function
  - `{:beam_call, name}` - JS `Beam.call("handler")` → Elixir handler fn
    registered via `QuickBEAM.start(handlers: %{...})`

  Also classifies effects for QuickBEAM API (`eval`/`call` → `:io`,
  `compile` → `:read`, `set_global` → `:write`), OXC (`parse`/`postwalk` →
  `:pure`, `transform`/`bundle` → `:io`), and Vize (→ `:io`).
  Auto-detected when `:quickbeam` is loaded.

- **Plugin API: `analyze_embedded/2`** - new optional callback that returns
  `{[Node.t()], [edge_spec()]}`, allowing plugins to inject IR nodes from
  embedded code (JS strings, SQL queries, etc.) and connect them to the
  host graph with cross-language edges.

### Improved

- **Dead code - near-zero false positives** - verified across Phoenix, Ecto,
  Oban, QuickBEAM, and Elixir stdlib (395 files). Remaining findings are all
  true positives.
  - Compiler directives (`import`, `alias`, `use`, `@spec`, `@type`,
    `defstruct`, `\\`, `<<>>`, `when`) no longer flagged
  - Type annotations inside `@spec`/`@type` bodies no longer flagged
  - Variables captured by closures (e.g. in `Enum.reduce` callbacks) tracked
    correctly via structural composite propagation through `:fn` and `:guard`
  - `with` clause value expressions alive (both `<-` patterns and bare
    assignments like `conn = put_in(...)` inside `with` blocks)
  - `receive` after-timeout expressions alive
  - `case`/`cond` subject expressions alive without making branch bodies
    alive (preserves dead code detection inside branches)
  - Struct pattern variable bindings (`%module{} = expr`) tracked
  - `unquote`/`unquote_splicing` variables inside `quote` blocks treated as
    references, not pattern definitions
  - `{:ok, _}` tuple return types in specs no longer infer `:pure`
  - Inferred-type purity requires concrete data types, rejects bare
    `%{dynamic: :term}` from NIF modules
  - Modules without typespecs no longer fall back to inferred-type purity

- **PDG containment edges** - added `:case`, `:fn`, `:receive`, `:try`, and
  `:guard` to `@value_types` in `DataDependence`, so `backward_slice` can
  traverse into control-flow constructs via graph edges instead of
  heuristic tree walks.

- **File I/O effect classification** - `File.read`/`stat`/`exists?` → `:read`,
  `File.write`/`cp`/`rm`/`mkdir` → `:write` (previously all `:io`).
  Erlang `:file` module similarly split.

- **Smell detection** - `Enum.map(rows, &List.first/1)` no longer flagged as
  the "Enum.map → List.first" anti-pattern. The detector now checks whether
  `List.first` is a mapper callback (descendant of `Enum.map`) vs a pipeline
  step. Field accesses and compiler directives excluded from redundant
  computation detection.

- **OTP analysis** - catch-all handler clauses (`_msg` / bare variable) now
  respected in unmatched-message detection.

### Fixed

- **`with` body translation** - `split_with_clauses` returned opts as
  `[[do: body]]` (list wrapping a keyword list), causing `Keyword.get` to
  return `nil`. The entire `with do...end` body was silently lost in all
  `with` blocks. Fixed by flattening opts. Pre-existing bug.

- **`with` bare expressions** - bare assignments inside `with` blocks
  (e.g. `conn = put_in(...)`) now preserved as `with_clause` nodes instead
  of being dropped by `split_with_clauses`.

- **`Code` and `Module` in `@impure_modules`** - `Code.ensure_loaded`,
  `Module.create` etc. no longer inferred as pure.

- **`:lists.foreach` in `@effectful_in_pure_modules`** - Erlang's
  `:lists.foreach/2` classified as `:io` (like `Enum.each/2`).

- **`:case` and `:fn` classified as `:pure`** - these are control flow
  constructs, not side effects. Previously classified as `:unknown`.

## 1.6.0

### Improved

- **Unified target format** - `reach.slice`, `reach.impact`, `reach.deps`,
  and `reach.graph` all accept both `Module.function/arity` and `file:line`
  formats. Previously `reach.slice` only accepted `file:line`, and
  `reach.impact`/`reach.deps` only accepted `Module.function/arity`.

- **100-500x faster function resolution** - indexed lookups replace linear
  scans of all IR nodes. On a 4k-function codebase: 10ms/call → 11-83μs/call.

- **Default argument awareness** - `find_function` matches functions called
  with fewer arguments than their definition (e.g. `foo/1` resolves to
  `def foo(a, b \\ nil)`).

### Fixed

- **Function resolution** - correctly resolve functions when module name
  casing differs from the source (e.g. QuickBEAM.Runtime vs
  Quickbeam.Runtime). Also handles projects where IR nodes store modules
  as nil by falling back to file path matching.

- **False positive elimination** - module-qualified lookups no longer fall
  back to unrelated functions when the target module isn't found.
  Verified zero false positives across 14 real codebases (22k+ functions).

### Internal

- Added `ex_dna` to `mix ci` and eliminated all 9 pre-existing code clones.
- Suppressed optional `boxart` undefined-module warnings via
  `@compile {:no_warn_undefined, ...}`.

## 1.5.1

### New

- **Ash Framework plugin** - effect classification and graph edges for the
  Ash ecosystem. Covers Ash core CRUD (`Ash.create/read/update/destroy` and
  bulk variants), `Ash.Changeset`, `Ash.Query`, `Ash.ActionInput`,
  `AshPhoenix.Form`, `Ash.Notifier`, resource DSL macros, and
  AshStateMachine DSL. Adds changeset-to-CRUD, query-to-read, form-to-submit,
  ActionInput-to-run_action flow edges, cross-module dispatch edges for
  `change`/`validate`/`prepare` callback modules, and code_interface
  `define`-to-action resolution. Auto-detected when the target project
  depends on `ash`.

### Fixed

- **Compilation without boxart** - `reach` now compiles and runs correctly
  without `boxart` installed. Struct literals (`%State{}`, `%PieChart{}`) that
  expanded at compile time have been replaced with runtime `struct!/2` calls.
  Graph commands raise a clear error when invoked without boxart (closes #9).

## 1.5.0

### New

- **7 analysis commands** for codebase-level insights:
  - `mix reach.coupling` - module-level coupling metrics (afferent/efferent
    coupling, Martin's instability metric, circular dependency detection).
    `--graph` renders the module dependency graph via boxart. `--orphans`
    shows unreferenced modules.
  - `mix reach.hotspots` - functions ranked by complexity × caller count,
    with clause breakdown for multi-clause dispatchers.
  - `mix reach.depth` - functions ranked by dominator tree depth (control
    flow nesting). `--graph` renders the CFG of the deepest function.
  - `mix reach.effects` - effect classification distribution across the
    codebase and top unclassified calls. `--graph` renders a pie chart.
  - `mix reach.xref` - cross-function data flow via the system dependence
    graph (parameter, return, state, and call edges between functions).
  - `mix reach.boundaries` - functions with multiple distinct side effects
    (read+write, write+send, etc.). `--min` sets the threshold.
  - `mix reach.concurrency` - Task.async/await pairing, process monitors,
    spawn/link chains, and supervisor topology.
- **Plugin `classify_effect/1` callback** - plugins can now teach the
  effect classifier about framework-specific calls. Implemented for all
  8 built-in plugins (Phoenix, Ecto, Oban, GenStage, Jido, OpenTelemetry,
  JSON).
- **Positional path filter** on all analysis commands - scope output to
  specific files or directories (e.g. `mix reach.hotspots lib/my_app/`).
- **Elixir 1.19+ inferred type classification** - reads ExCk BEAM chunk
  for compiler-inferred type signatures. Functions returning data types
  are classified as `:pure`. Gracefully disabled on older Elixir versions.

### Improved

### Fixed

- **Function resolution** - correctly resolve functions when module name
  casing differs from the source (e.g. QuickBEAM.Runtime vs
  Quickbeam.Runtime). Also handles projects where IR nodes store modules
  as nil by falling back to file path matching.


- **Alias resolution** - `alias Plausible.Ingestion.Event` then
  `Event.build()` now correctly resolves to `Plausible.Ingestion.Event`.
  Handles simple aliases, `:as` aliases, and multi-alias `{}` syntax.
  Scoped per module - aliases don't leak across `defmodule` boundaries.
- **Import resolution** - `import Ecto.Query` then bare `from(...)` now
  resolves to `Ecto.Query.from`. Handles `:only` and `:except` options.
  Gracefully skips unloaded modules.
- **Field access detection** - `socket.assigns`, `conn.params`, `state.count`
  are recognized as field access (`kind: :field_access`) instead of
  remote calls with a fake module name. Classified as `:pure`.
- **Compile-time noise filtering** - `@doc`, `@spec`, `@type`, `use`,
  `import`, `alias`, `require`, `::`, `__aliases__`, typespec names, and
  binary syntax are classified as `:pure` instead of `:unknown`.
- **Local function effect inference** - fixed-point iteration over function
  bodies infers effects from callees. Propagates across module boundaries
  via module-qualified cache keys.
- **Expanded pure modules** - `Access`, `Calendar`, `Date`, `DateTime`,
  `NaiveDateTime`, `Time`.
- **Reclassified stdlib functions**:
  - `Kernel.to_string` and other builtins classified correctly when module
    is explicit.
  - `Enum.each` → `:io` (was `:unknown`).
  - `Application.get_env`, `System.get_env` → `:read`.
  - `System.monotonic_time`, `Mix.env` → `:read`.
  - `GenServer.start_link`, `Supervisor.start_link` → `:io`.
  - `Supervisor.child_spec` → `:pure`.
  - `:atomics`/`:counters` → `:read`/`:write` (was `:nif`).
  - `:persistent_term` → `:read`/`:write` (was `:nif`).
  - `:no_return` and `:string` recognized as pure return types in specs.
- **Plugin effect classification**:
  - Phoenix: route helpers, `assign`, `push_event`, `attr`, `slot`,
    `sigil_H`, router DSL → `:pure`.
  - Ecto: query DSL → `:pure`, Repo reads → `:read`, writes → `:write`,
    changeset/schema macros → `:pure`.
  - Oban: `Oban.insert` → `:write`, `start_link`/`drain_queue` → `:io`.
  - GenStage: `call`/`cast` → `:send`, Broadway.Message → `:pure`.
  - Jido: updated to v2 API. Signal dispatch → `:send`, directives →
    `:io`/`:send`, Thread → `:pure`, memory → `:read`/`:write`.
  - OpenTelemetry: Tracer spans → `:io`, context → `:read`/`:write`,
    `:telemetry.execute` → `:io`.
  - JSON: all Jason/Poison functions → `:pure`.
- **Boxart integration**:
  - `reach.otp --graph` uses `Boxart.Render.StateDiagram` for GenServer
    state machines.
  - `reach.effects --graph` uses `Boxart.Render.PieChart` for effect
    distribution.
  - Upgraded boxart to 0.3.2.
- **Clause breakdown** in `reach.hotspots` and `reach.depth` - multi-clause
  functions show dispatch labels (e.g. "53 clauses: save, delete, ...").
- **Shared helpers** - clause_labels/1 and
  `Format.threshold_color/3` extracted from duplicated code.
- **Unknown call ratio dropped from ~89% to ~11%** across real codebases
  (tested on Plausible, Livebook, Tymeslot, OpenPace, Beacon, Ecto, Oban).

### Performance

- **~30% faster project analysis** (Plausible 466 files: 2.7s → 1.9s).
- Reach.Graph.merge/1 - direct map merge instead of per-edge
  `Graph.add_edges` loop.
- `HigherOrder.add_edges` - moved `pure_call?` typespec check from hot
  path to one-time catalog build.
- Eliminated redundant `IR.all_nodes` traversals in SDG build and effect
  inference.
- Stored `func_def` directly in PDG map, avoiding linear scan in
  `build_external_sdg_map`.

## 1.4.1

### Fixed

- `mix reach.modules`, `mix reach.impact`, and `mix reach.slice` crash with
  `BadBooleanError` when `--graph` is not passed (closes #6).

## 1.4.0

### New

- **Terminal graph rendering** via optional `boxart` dependency:
  - `mix reach.graph Mod.fun/arity` - control flow graph with syntax-highlighted
    source code and line numbers in each node
  - `mix reach.graph Mod.fun/arity --call-graph` - callee tree as mindmap
  - `mix reach.deps Mod.fun/arity --graph` - callee tree visualization
  - `mix reach.impact Mod.fun/arity --graph` - caller tree visualization
  - `mix reach.modules --graph` - module dependency graph (internal only)
  - `mix reach.otp --graph` - GenServer state diagrams per module
  - `mix reach.slice file:line --graph` - slice subgraph

### Improved

### Fixed

- **Function resolution** - correctly resolve functions when module name
  casing differs from the source (e.g. QuickBEAM.Runtime vs
  Quickbeam.Runtime). Also handles projects where IR nodes store modules
  as nil by falling back to file path matching.


- CFG rendering reuses `Visualize.ControlFlow.build_function/2` - same
  line ranges, block merging, and source extraction as the HTML visualization
- Graph output clamped to terminal width via `Boxart.render max_width`
- CFG code blocks dedented to match HTML visualization indentation
- Same-line CFG vertices merged (no more duplicate nodes)

## 1.3.0

### New

- **8 mix tasks for code analysis** - agent-oriented CLI tools that expose
  Reach's graph analysis as structured text/JSON output:
  - `mix reach.modules` - bird's-eye codebase inventory sorted by
    name/functions/complexity, with OTP/LiveView behaviour detection
  - `mix reach.dead_code` - find unused pure expressions (parallel per-file)
  - `mix reach.deps` - direct callers, callee tree, shared state writers
  - `mix reach.impact` - transitive callers, return value dependents, risk
  - `mix reach.flow` - taint analysis (`--from`/`--to`) and variable tracing
  - `mix reach.slice` - backward/forward program slicing by file:line
  - `mix reach.otp` - GenServer state machines, ETS/process dictionary
    coupling, missing message handlers, supervision tree
  - `mix reach.smell` - cross-function performance anti-patterns (redundant
    traversals, duplicate computations, eager patterns)
  - All tools support `--format text` (colored), `json`, and `oneline`
- **Dynamic dispatch in Elixir frontend** - `handler.(args)` and `fun.(args)`
  now emit `:call` nodes with `kind: :dynamic` (closes #4)
- **ANSI color output** - headers cyan, function names bright, file paths
  faint, complexity colored by severity, OTP state actions colored by type.
  Auto-disabled when piped.

### Fixed

- **BEAM frontend source_span normalization** - `:erl_anno` annotations
  (integer, `{line, col}` tuple, keyword list, or nil) now normalized via
  `:erl_anno.line/1` and `:erl_anno.column/1`. `start_line` is always integer
  or nil. Column info extracted from `{line, col}` tuples (closes #5).
- **Visualization crash on BEAM modules** - `build_def_line_map` and
  `cached_file_lines` now skip non-source files and validate UTF-8.
- **dead_code false positives reduced 91%** (628 → 58 on Phoenix) -
  fixed-point alive expansion for intermediate variables, branch-tail return
  tracing through case/cond/try/fn, guard exclusion, comprehension
  generator/filter exclusion, cond condition exclusion, `<>` pattern
  recognition, impure module blocklist (`Process`, `:code`, `:ets`, `Node`,
  `System`, etc.), typespec exclusion, impure call descendant marking.
- **reach.smell false positives** - structural pipe check instead of
  transitive graph reachability, per-clause redundant computation grouping,
  full argument comparison (vars + literals), type-check function exclusion,
  function reference filtering, callback purity check for map→map fusion.
- **reach.otp state detection** - finds struct field access (`state.field`),
  unwraps `%State{} = state` patterns, detects ETS writes through state
  parameter. No longer flags `Map.merge` on non-state variables.
- **reach.deps** shows only direct callers (transitive analysis in
  reach.impact).
- **Block quality** - `compute_vertex_ranges` uses `min_line_in_subtree` to
  include multi-line pattern children.

### Improved

### Fixed

- **Function resolution** - correctly resolve functions when module name
  casing differs from the source (e.g. QuickBEAM.Runtime vs
  Quickbeam.Runtime). Also handles projects where IR nodes store modules
  as nil by falling back to file path matching.


- **Performance** - effect classification cached in ETS (shared across
  parallel tasks), SDG construction parallelized across modules.
  Livebook analysis: 9.7s → 3.5s.
- **Consistent CLI output** - `(none found)` everywhere, descriptive match
  descriptions (`name = Module.func is unused`), empty slice suggests
  `--forward`, zero-function modules filtered from reach.modules.

## 1.2.0

### New

- **Gleam support** - analyze `.gleam` source files with accurate line mapping.
  Uses the `glance` parser (Gleam's own parser, written in Gleam) for native AST
  parsing with byte-offset spans. Supports case expressions, pattern matching with
  guards, pipes, anonymous functions, record updates, and all standard Gleam
  constructs. Requires `gleam build` and glance on the code path.

### Fixed

- Unreachable `block_label/5` catch-all clause removed (Dialyzer).
- `file_to_graph/2` cyclomatic complexity reduced - extracted `parse_file_and_build/3`
  and `read_and_build_elixir/2`.
- `func_end_line/2` simplified - extracted `find_nearest_end/2`.
- `apply/3` used for optional `:glance` module to avoid compile-time warnings.
- Empty blocks from line clamping filtered out in visualization.
- Exit nodes show label in Vue component (no more invisible gray bars).
- Block end_line uses max across all vertices (fixes multi-line heredoc coverage).
- Block overlap elimination - end_line clamping considers all blocks globally.
- `repo_module?/1` crash on capture syntax `& &1.name` (closes #3).

## 1.1.3

### Fixed

- Crash in `Reach.Plugins.Ecto.repo_module?/1` on capture syntax like
  `& &1.name` where call meta contains AST tuples instead of atoms (closes #3).
- Block end_line now uses max across all vertices in the block, fixing missing
  coverage for multi-line heredoc strings inside if/case branches.
- Block overlap elimination - end_line clamping now considers all blocks
  globally, not just the next one in traversal order (155 → 0 overlaps).
- Multi-clause dispatch functions now connect exit nodes via
  `find_exit_predecessors` instead of leaving them disconnected.

### Audited

16,047 functions across 1,213 files (Elixir, Phoenix, Ecto, Oban, Plausible,
Livebook): 0 empty blocks, 0 nil labels, 0 overlaps, 0 duplicate lines,
0 missing exits, 0 disconnected exits.

## 1.1.2

### Fixed

- **Anonymous fn bodies inlined into parent CFG** - `Enum.reduce(fn ... end)`
  callbacks with internal branching (case/if/raise) are now decomposed into
  visible control flow blocks instead of being opaque single nodes.
- **Block merging for same-line nested constructs** - inline `if x, do: a, else: b`
  no longer creates monster merged blocks like `b_1490_1485_1489_1478`.
  Branch detection now includes clause targets and multi-out vertices.
- **Source extraction for clauses without source spans** - multi-clause function
  heads (e.g. `def foo(:join, :inner)`) that lack compiler source spans now show
  source code via child node line walking instead of empty gray blocks.
- **Block disjointness** - overlapping blocks eliminated (533 → 0) by clamping
  block end_line to `(next_block_start - 1)` and removing duplicate line ranges
  from dispatch clause blocks.
- **Missing exit nodes** - multi-clause dispatch functions now include proper
  exit nodes (58 missing → 0).
- **Pure pattern-matching dispatches** - functions like `join_qual/1` with 9
  one-line clauses render as a single function node instead of a useless
  dispatch → 9 disconnected clause blocks.
- **Preamble/sidebar spam removed** - the sidebar no longer shows `@doc`,
  `@moduledoc`, `use`, `import` lines extracted by string matching. Sidebar
  shows only module name and function list.
- **Render patterns** added for `:pin`, `:binary_op`, `:unary_op`, `:cons`,
  `:guard`, `:generator`, `:filter`, `:module_def` node types.

### Added

- **Block quality audit test** - validates 6 acceptance criteria (coverage,
  disjointness, no empty blocks, no nil labels, entry/exit structure) across
  real codebases (Ecto, Phoenix, Oban).

## 1.1.1

### Fixed

- Crash (`FunctionClauseError`) on macro definitions that look like `if/unless`
  calls with non-keyword-list branches (e.g. `defmacro if(condition, clauses)`
  in Elixir's own `Kernel`).
- Crash when `case/cond/receive` do-blocks contain `unquote` splices instead
  of a normal clause list (macro-heavy code like `Macro`, `ExUnit.Callbacks`).
- `hd([])` crash in control-flow builder on code with empty exit sets
  (e.g. single-clause `cond do true -> :ok end`).
- Struct/map pattern rendering crash with field bindings (from PR #2).

### Tested

Smoke-tested on 3,024 files across 8 major Elixir projects with zero failures:
elixir, phoenix, ecto, oban, plausible, livebook, blockscout, firezone.

## 1.1.0

### New

- **Plugin system** - `Reach.Plugin` behaviour for library-specific analysis.
  Auto-detects Phoenix, Ecto, Oban, GenStage, Jido, and OpenTelemetry at
  runtime. Override with `plugins:` option.
- **`mix reach` task** - generates self-contained interactive HTML report with
  three visualization modes: Control Flow, Call Graph, and Data Flow.
- **Expression-level control flow graph** - source-primary visualization where
  every line of every function is visible. Branch points (if/case/unless) show
  fan-out edges, all paths converge at merge points with blue converge edges.
- **Core CFG expansion** - Reach.ControlFlow.build/1 now correctly expands
  branches nested inside pipes, assignments, and calls. `if ... end |> f()`
  shows both branches converging at the pipe call.
- **Intra-function data flow** - Data Flow tab shows variable def→use chains
  within each function, labeled with variable names.
- **Module preamble** - sidebar shows `use`/`import`/`alias`/`@attributes` as
  a collapsed header, not separate nodes.
- **Syntax highlighting** - Makeup-powered server-side highlighting in all
  code blocks, with proper indentation preservation via common-prefix dedent.
- **Multi-clause dispatch** - pattern-match dispatch nodes with colored
  clause edges for functions with multiple `def` heads.
- **6 built-in plugins**: Phoenix, Ecto, Oban, GenStage, Jido, OpenTelemetry.

### Improved

### Fixed

- **Function resolution** - correctly resolve functions when module name
  casing differs from the source (e.g. QuickBEAM.Runtime vs
  Quickbeam.Runtime). Also handles projects where IR nodes store modules
  as nil by falling back to file path matching.


- **Call graph** - filtered Ecto query bindings, pipe operators, kernel ops,
  Ecto DSL macros; nil module resolved to detected module; deduplicated edges.
- **Text selection** - code blocks now allow text selection (`user-select: text`,
  nodes not draggable).
- **Sidebar navigation** - click scrolls and zooms to function, highlights all
  nodes of selected function with blue glow, dims others. Click background to
  clear.

### Fixed

- Crash on `key :start_line not found` when processing branch expressions.
- Node ID collisions in `Reach.Project` parallel file parsing (shared
  `:atomics` counter).
- Module name extraction fallback when path has no `lib/src` prefix.

## 1.0.0

First public release.

### Core analysis

- **Program Dependence Graph** - builds a graph capturing data and control
  dependencies for Elixir and Erlang source code. Every expression knows what
  it depends on and what depends on it.
- **Scope-aware data dependence** - variable definitions resolve through
  lexical scope chains. Variables in case clauses, fn bodies, and
  comprehensions don't leak to sibling scopes.
- **Binding role tracking** - pattern variables (`x` in `x = foo()`, `{a, b}`)
  are tagged as definitions at IR construction time. Data edges go from
  definition vars to use vars, not from clauses.
- **Match binding edges** - `z = x ++ y` creates `:match_binding` edges from
  the RHS expression to the LHS definition var, enabling transitive data flow
  through assignments.
- **Containment edges** - parent expressions depend on their child
  sub-expressions. `backward_slice(x + 1)` reaches both `x` and `1`.
- **Multi-clause function grouping** - `def foo(:a)` + `def foo(:b)` in the
  same module are merged into one function definition with proper dispatch
  control flow (`:clause_match` / `:clause_fail` edges).

### Three frontends

- **Elixir source** - `Reach.string_to_graph/2`, `Reach.file_to_graph/2`.
  Handles all Elixir constructs: match, case, cond, with/else, try/rescue/after,
  receive/timeout, for comprehensions, pipe chains (desugared), capture
  operators (`&fun/1`, `&Mod.fun/1`, `&(&1 + 1)`), `if`/`unless` (desugared
  to case), guards, anonymous functions, structs, maps, dot access on variables.
- **Erlang source** - `Reach.string_to_graph(source, language: :erlang)`,
  auto-detected for `.erl` files. Parses via `:epp`, translates Erlang abstract
  forms to the same IR.
- **BEAM bytecode** - `Reach.module_to_graph/2`, `Reach.compiled_to_graph/2`.
  Analyzes macro-expanded code from compiled `.beam` files. Sees `use GenServer`
  injected callbacks, macro-expanded `try/rescue`, generated functions.

### Slicing and queries

- `Reach.backward_slice/2` - what affects this expression?
- `Reach.forward_slice/2` - what does this expression affect?
- `Reach.chop/3` - nodes on all paths from A to B.
- `Reach.independent?/3` - can two expressions be safely reordered? Checks
  data flow (including descendant nodes), control dependencies, and side effect
  conflicts.
- `Reach.nodes/2` - filter nodes by `:type`, `:module`, `:function`, `:arity`.
- `Reach.neighbors/3` - direct neighbors with optional label filter.
- `Reach.data_flows?/3` - does data flow from source to sink? Checks
  descendant nodes of both source and sink.
- `Reach.depends?/3`, `Reach.has_dependents?/2`, `Reach.controls?/3`.
- `Reach.passes_through?/4` - does the flow path pass through a node matching
  a predicate?

### Taint analysis

- `Reach.taint_analysis/2` - declarative taint analysis with keyword filters
  (same format as `nodes/2`) or predicate functions. Returns source, sink,
  path, and whether sanitization was found.

### Dead code detection

- `Reach.dead_code/1` - finds pure expressions whose values are never used and
  don't contribute to any observable output (return values or side-effecting
  calls). Excludes module attributes, typespecs, and vars (compiler handles
  those).

### Effect classification

- `Reach.pure?/1`, `Reach.classify_effect/1` - classifies calls as `:pure`,
  `:io`, `:read`, `:write`, `:send`, `:receive`, `:exception`, `:nif`, or
  `:unknown`.
- Hardcoded database covers 30+ pure modules (Enum, Map, List, String, etc.)
  plus Erlang equivalents.
- `Enum.each` correctly classified as impure.
- **Type-aware inference** - functions not in the hardcoded database are
  auto-classified by extracting `@spec` via `Code.Typespec.fetch_specs`.
  Functions returning only data types are inferred as pure; functions returning
  `:ok` are left as unknown.

### Higher-order function resolution

- Auto-generated catalog of 1,000+ functions from pure modules where parameters
  flow to return value. Covers Enum, Stream, Map, String, List, Keyword, Tuple,
  and Erlang equivalents.
- `:higher_order` edges connect flowing arguments to call results.
- Impure functions (like `Enum.each`) excluded - their param flow is for side
  effects, not return value production.

### Interprocedural analysis

- **Call graph** - `{module, function, arity}` vertices with call edges.
- **System Dependence Graph** - per-function PDGs connected through `:call`,
  `:parameter_in`, `:parameter_out`, and `:summary` edges.
- **Context-sensitive slicing** - Horwitz-Reps-Binkley two-phase algorithm
  avoids impossible paths through call sites.
- **Cross-module resolution** - `Reach.Project` links call edges across
  modules and applies external dependency summaries.

### OTP awareness

- **GenServer state threading** - `:state_read` edges from callback state
  parameter to uses, `:state_pass` edges between consecutive callback returns.
- **Message content flow** - `send(pid, {:tag, data})` creates
  `{:message_content, :tag}` edges to `handle_info({:tag, payload})` pattern
  vars. Tags must match.
- **GenServer.call reply flow** - `{:reply, value, state}` creates
  `:call_reply` edges from reply value back to `GenServer.call` call site.
- **ETS dependencies** - `{:ets_dep, table}` edges between writes and reads
  on the same table, with table name tracking.
- **Process dictionary** - `{:pdict_dep, key}` edges between `Process.put`
  and `Process.get` on the same key.
- **Message ordering** - `:message_order` edges between sequential sends to
  the same target pid.

### Concurrency analysis

- **Process.monitor → :DOWN** - `:monitor_down` edges from monitor calls to
  `handle_info({:DOWN, ...})` handlers in the same module.
- **trap_exit → :EXIT** - `:trap_exit` edges from `Process.flag(:trap_exit)`
  to `handle_info({:EXIT, ...})` handlers.
- **spawn_link / Process.link** - `:link_exit` edges to `:EXIT` handlers.
- **Task.async → Task.await** - `:task_result` edges paired by module scope
  and position order.
- **Supervisor children** - `:startup_order` edges from child ordering in
  `init/1`.

### Multi-file project analysis

- `Reach.Project.from_sources/2`, `from_glob/2`, `from_mix_project/1` -
  parallel file parsing, cross-module call resolution, merged project graph.
- `Reach.Project.taint_analysis/2` - taint analysis across all modules.
- `Reach.Project.summarize_dependency/1` - compute param→return flow summaries
  for compiled dependency modules.

### Canonical ordering

- `Reach.canonical_order/2` - sorts block children so independent siblings
  have deterministic order regardless of source order. Dependent expressions
  preserve relative order. Enables Type IV reordering-equivalent clone
  detection in ExDNA.

### Integration

- `Reach.ast_to_graph/2` - build graph from pre-parsed Elixir AST (for
  Credo/ExDNA integration, no re-parsing).
- `Reach.to_graph/1` - returns the underlying `Graph.t()` (libgraph) for
  power users who need path finding, subgraphs, BFS/DFS, etc.
- `Reach.to_dot/1` - Graphviz DOT export.

### Performance

Benchmarked on real projects (Apple M1 Pro):

| Project | Files | Time |
|---------|-------|------|
| ex_slop | 26 | 36ms |
| ex_dna | 32 | 87ms |
| Livebook | 72 | 160ms |
| Oban | 64 | 195ms |
| Keila | 190 | 282ms |
| Phoenix | 74 | 333ms |
| Absinthe | 282 | 375ms |

740 files, zero crashes.
