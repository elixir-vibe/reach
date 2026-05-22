defmodule Reach.ConfigTest do
  use ExUnit.Case, async: true

  alias Reach.Config

  test "normalizes grouped policy sections into structs" do
    assert %Config{} =
             config =
             Config.normalize(
               layers: [domain: "MyApp.*"],
               deps: [
                 mode: :allowlist,
                 allowed: [domain: [:web]],
                 forbidden: [{:domain, :web, except: ["MyApp.Domain.Legacy"]}]
               ],
               calls: [forbidden: [{"MyApp.*", ["IO.puts"]}]],
               effects: [
                 allowed: [{"MyApp.Pure.*", [:pure]}],
                 by_layer: [domain: [:pure], web: :any]
               ],
               boundaries: [
                 public: ["MyApp.Accounts"],
                 internal: ["MyApp.Accounts.Internal.*"],
                 internal_callers: [{"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}]
               ],
               tests: [hints: [{"lib/my_app/**", ["test/my_app"]}]],
               source: [
                 forbidden_modules: ["MyApp.Legacy.*"],
                 forbidden_files: ["lib/my_app/legacy/**"]
               ],
               risk: [
                 changed: [
                   many_direct_callers: 4,
                   wide_transitive_callers: 9,
                   branch_heavy: 7,
                   high_risk_reason_count: 2
                 ]
               ],
               checks: [
                 baseline: ".reach-baseline.json",
                 layer_coverage: [
                   require_all_modules: true,
                   forbid_multiple_matches: true,
                   ignore: ["Mix.Tasks.*"]
                 ]
               ],
               candidates: [
                 thresholds: [
                   mixed_effect_count: 3,
                   branchy_function_branches: 9,
                   high_risk_direct_callers: 5
                 ],
                 limits: [
                   per_kind: 30,
                   representative_calls: 12,
                   representative_calls_per_edge: 2
                 ]
               ],
               smells: [
                 strict: true,
                 custom_checks: [MyApp.ReachSmells.NoFoo],
                 fixed_shape_map: [
                   min_keys: 4,
                   min_occurrences: 5,
                   evidence_limit: 6
                 ],
                 behaviour_candidate: [
                   min_modules: 2,
                   min_callbacks: 2,
                   module_display_limit: 4,
                   callback_display_limit: 5
                 ]
               ],
               clone_analysis: [
                 provider: :ex_dna,
                 min_mass: 12,
                 min_similarity: 0.9,
                 max_clones: 7
               ]
             )

    assert config.layers == [domain: "MyApp.*"]
    assert config.deps.mode == :allowlist
    assert config.deps.allowed == [domain: [:web]]
    assert config.deps.forbidden == [{:domain, :web, except: ["MyApp.Domain.Legacy"]}]
    assert config.calls.forbidden == [{"MyApp.*", ["IO.puts"]}]
    assert config.effects.allowed == [{"MyApp.Pure.*", [:pure]}]
    assert config.effects.by_layer == [domain: [:pure], web: :any]
    assert config.boundaries.public == ["MyApp.Accounts"]
    assert config.boundaries.internal == ["MyApp.Accounts.Internal.*"]

    assert config.boundaries.internal_callers == [
             {"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}
           ]

    assert config.tests.hints == [{"lib/my_app/**", ["test/my_app"]}]
    assert config.source.forbidden_modules == ["MyApp.Legacy.*"]
    assert config.source.forbidden_files == ["lib/my_app/legacy/**"]
    assert config.risk.changed.many_direct_callers == 4
    assert config.risk.changed.wide_transitive_callers == 9
    assert config.risk.changed.branch_heavy == 7
    assert config.risk.changed.high_risk_reason_count == 2
    assert config.checks.baseline == ".reach-baseline.json"
    assert config.checks.layer_coverage.require_all_modules == true
    assert config.checks.layer_coverage.forbid_multiple_matches == true
    assert config.checks.layer_coverage.ignore == ["Mix.Tasks.*"]
    assert config.candidates.thresholds.mixed_effect_count == 3
    assert config.candidates.thresholds.branchy_function_branches == 9
    assert config.candidates.thresholds.high_risk_direct_callers == 5
    assert config.candidates.limits.per_kind == 30
    assert config.candidates.limits.representative_calls == 12
    assert config.candidates.limits.representative_calls_per_edge == 2
    assert config.smells.strict == true
    assert config.smells.custom_checks == [MyApp.ReachSmells.NoFoo]
    assert config.smells.fixed_shape_map.min_keys == 4
    assert config.smells.fixed_shape_map.min_occurrences == 5
    assert config.smells.fixed_shape_map.evidence_limit == 6
    assert config.smells.behaviour_candidate.min_modules == 2
    assert config.smells.behaviour_candidate.min_callbacks == 2
    assert config.smells.behaviour_candidate.module_display_limit == 4
    assert config.smells.behaviour_candidate.callback_display_limit == 5
    assert config.clone_analysis.provider == :ex_dna
    assert config.clone_analysis.min_mass == 12
    assert config.clone_analysis.min_similarity == 0.9
    assert config.clone_analysis.max_clones == 7
  end

  test "accepts flat compatibility aliases" do
    assert %Config{} =
             config =
             Config.normalize(
               forbidden_deps: [{:domain, :web}],
               forbidden_calls: [{"MyApp.*", ["IO.puts"]}],
               allowed_effects: [{"MyApp.Pure.*", [:pure]}],
               public_api: ["MyApp.Accounts"],
               internal: ["MyApp.Accounts.Internal.*"],
               internal_callers: [{"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}],
               test_hints: [{"lib/my_app/**", ["test/my_app"]}],
               forbidden_modules: ["MyApp.Legacy.*"],
               forbidden_files: ["lib/my_app/legacy/**"]
             )

    assert config.deps.forbidden == [{:domain, :web}]
    assert config.calls.forbidden == [{"MyApp.*", ["IO.puts"]}]
    assert config.effects.allowed == [{"MyApp.Pure.*", [:pure]}]
    assert config.boundaries.public == ["MyApp.Accounts"]
    assert config.boundaries.internal == ["MyApp.Accounts.Internal.*"]

    assert config.boundaries.internal_callers == [
             {"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}
           ]

    assert config.tests.hints == [{"lib/my_app/**", ["test/my_app"]}]
    assert config.source.forbidden_modules == ["MyApp.Legacy.*"]
    assert config.source.forbidden_files == ["lib/my_app/legacy/**"]
  end

  test "reports unknown layer references" do
    assert {:error, errors} =
             Config.from_terms(
               layers: [domain: "MyApp.Domain.*"],
               deps: [forbidden: [{:domain, :web}], allowed: [domain: [:repo]]],
               effects: [by_layer: [logic: [:pure]]]
             )

    messages = Enum.map(errors, & &1.message)

    assert Enum.any?(messages, &(&1 =~ "unknown layer :web"))
    assert Enum.any?(messages, &(&1 =~ "unknown layer :repo"))
    assert Enum.any?(messages, &(&1 =~ "unknown layer :logic"))
  end

  test "rejects allowlist deps combined with forbidden deps" do
    assert {:error, errors} =
             Config.from_terms(
               layers: [domain: "MyApp.Domain.*", web: "MyAppWeb.*"],
               deps: [mode: :allowlist, allowed: [domain: [:web]], forbidden: [{:web, :domain}]]
             )

    assert Enum.any?(errors, &(&1.message =~ "cannot be combined"))
  end

  test "reports nested config error paths" do
    assert {:error, errors} =
             Config.from_terms(
               deps: [forbidden: :bad, unexpected: []],
               risk: [changed: [branch_heavy: 0]],
               candidates: [thresholds: [mixed_effect_count: "many"]],
               smells: [fixed_shape_map: [min_keys: 0]],
               clone_analysis: [provider: :unknown]
             )

    violations = Enum.map(errors, &Config.Error.to_violation/1)

    assert %{key: "deps.forbidden", path: ["deps", "forbidden"]} =
             Enum.find(violations, &(&1.key == "deps.forbidden"))

    assert %{key: "deps.unexpected", path: ["deps", "unexpected"]} =
             Enum.find(violations, &(&1.key == "deps.unexpected"))

    assert %{key: "risk.changed.branch_heavy"} =
             Enum.find(violations, &(&1.key == "risk.changed.branch_heavy"))

    assert %{key: "candidates.thresholds.mixed_effect_count"} =
             Enum.find(violations, &(&1.key == "candidates.thresholds.mixed_effect_count"))

    assert %{key: "smells.fixed_shape_map.min_keys"} =
             Enum.find(violations, &(&1.key == "smells.fixed_shape_map.min_keys"))

    assert %{key: "clone_analysis.provider"} =
             Enum.find(violations, &(&1.key == "clone_analysis.provider"))
  end
end
