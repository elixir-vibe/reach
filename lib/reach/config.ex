defmodule Reach.Config do
  @moduledoc "Parses and normalizes .reach.exs architecture policy configuration."

  alias Reach.Check.Violation

  defmodule Deps do
    @moduledoc false
    defstruct forbidden: [], mode: :forbidlist, allowed: []
  end

  defmodule Calls do
    @moduledoc false
    defstruct forbidden: []
  end

  defmodule Effects do
    @moduledoc false
    defstruct allowed: [], by_layer: []
  end

  defmodule Boundaries do
    @moduledoc false
    defstruct public: [], internal: [], internal_callers: []
  end

  defmodule Tests do
    @moduledoc false
    defstruct hints: []
  end

  defmodule Source do
    @moduledoc false
    defstruct forbidden_modules: [], forbidden_files: []
  end

  defmodule Risk do
    @moduledoc false
    defstruct changed: nil
  end

  defmodule Risk.Changed do
    @moduledoc false
    defstruct many_direct_callers: 5,
              wide_transitive_callers: 10,
              branch_heavy: 8,
              high_risk_reason_count: 3
  end

  defmodule Candidates do
    @moduledoc false
    defstruct thresholds: nil, limits: nil
  end

  defmodule Candidates.Thresholds do
    @moduledoc false
    defstruct mixed_effect_count: 2,
              branchy_function_branches: 8,
              high_risk_direct_callers: 4
  end

  defmodule Candidates.Limits do
    @moduledoc false
    defstruct per_kind: 20,
              representative_calls: 10,
              representative_calls_per_edge: 3
  end

  defmodule CloneAnalysis do
    @moduledoc false
    defstruct provider: :ex_dna,
              min_mass: 30,
              min_similarity: 1.0,
              max_clones: 50
  end

  defmodule Checks do
    @moduledoc false
    defstruct baseline: nil, layer_coverage: nil
  end

  defmodule Checks.LayerCoverage do
    @moduledoc false
    defstruct require_all_modules: false,
              forbid_multiple_matches: false,
              ignore: []
  end

  defmodule Smells do
    @moduledoc false
    defstruct strict: false,
              custom_checks: [],
              fixed_shape_map: nil,
              behaviour_candidate: nil
  end

  defmodule Smells.FixedShapeMap do
    @moduledoc false
    defstruct min_keys: 3,
              min_occurrences: 3,
              evidence_limit: 10
  end

  defmodule Smells.BehaviourCandidate do
    @moduledoc false
    defstruct min_modules: 3,
              min_callbacks: 3,
              module_display_limit: 8,
              callback_display_limit: 8
  end

  defmodule Error do
    @moduledoc false
    defstruct [:path, :message]

    def to_violation(%__MODULE__{path: path, message: message}) do
      wrapped_path = List.wrap(path)
      key = Enum.map_join(wrapped_path, ".", &to_string/1)

      Violation.new(
        type: :config_error,
        key: key,
        path: Enum.map(wrapped_path, &to_string/1),
        message: message
      )
    end
  end

  defstruct layers: [],
            deps: nil,
            calls: nil,
            effects: nil,
            boundaries: nil,
            tests: nil,
            source: nil,
            risk: nil,
            candidates: nil,
            checks: nil,
            smells: nil,
            clone_analysis: nil

  @top_level_keys [
    :layers,
    :deps,
    :calls,
    :effects,
    :boundaries,
    :tests,
    :source,
    :risk,
    :candidates,
    :checks,
    :smells,
    :clone_analysis,
    :forbidden_deps,
    :allowed_effects,
    :forbidden_calls,
    :public_api,
    :internal,
    :internal_callers,
    :test_hints,
    :forbidden_modules,
    :forbidden_files
  ]

  def read(path \\ ".reach.exs") do
    if File.exists?(path), do: Code.eval_file(path) |> elem(0), else: []
  end

  def read!(path \\ ".reach.exs") do
    unless File.exists?(path) do
      Mix.raise("No #{path} architecture policy found")
    end

    config = Code.eval_file(path) |> elem(0)

    unless is_list(config) do
      Mix.raise("#{path} must evaluate to a keyword list")
    end

    config
  end

  def from_terms(%__MODULE__{} = config), do: {:ok, normalize(config)}

  def from_terms(config) when is_list(config) do
    errors = errors(config)

    if errors == [] do
      {:ok, normalize(config)}
    else
      {:error, errors}
    end
  end

  def from_terms(_config) do
    {:error, [%Error{path: [], message: "expected .reach.exs to evaluate to a keyword list"}]}
  end

  def normalize(%__MODULE__{} = config) do
    %__MODULE__{
      config
      | deps: config.deps || %Deps{},
        calls: config.calls || %Calls{},
        effects: config.effects || %Effects{},
        boundaries: config.boundaries || %Boundaries{},
        tests: config.tests || %Tests{},
        source: config.source || %Source{},
        risk: normalize_risk(config.risk),
        candidates: normalize_candidates(config.candidates),
        checks: normalize_checks(config.checks),
        smells: normalize_smells(config.smells),
        clone_analysis: normalize_clone_analysis(config.clone_analysis)
    }
  end

  def normalize(config) when is_list(config) do
    %__MODULE__{
      layers: Keyword.get(config, :layers, []),
      deps: %Deps{
        forbidden: nested(config, [:deps, :forbidden], :forbidden_deps, []),
        mode: nested(config, [:deps, :mode], nil, :forbidlist),
        allowed: nested(config, [:deps, :allowed], nil, [])
      },
      calls: %Calls{forbidden: nested(config, [:calls, :forbidden], :forbidden_calls, [])},
      effects: %Effects{
        allowed: nested(config, [:effects, :allowed], :allowed_effects, []),
        by_layer: nested(config, [:effects, :by_layer], nil, [])
      },
      boundaries: %Boundaries{
        public: nested(config, [:boundaries, :public], :public_api, []),
        internal: nested(config, [:boundaries, :internal], :internal, []),
        internal_callers: nested(config, [:boundaries, :internal_callers], :internal_callers, [])
      },
      tests: %Tests{hints: nested(config, [:tests, :hints], :test_hints, [])},
      source: %Source{
        forbidden_modules: nested(config, [:source, :forbidden_modules], :forbidden_modules, []),
        forbidden_files: nested(config, [:source, :forbidden_files], :forbidden_files, [])
      },
      risk: %Risk{
        changed: %Risk.Changed{
          many_direct_callers: nested(config, [:risk, :changed, :many_direct_callers], nil, 5),
          wide_transitive_callers:
            nested(config, [:risk, :changed, :wide_transitive_callers], nil, 10),
          branch_heavy: nested(config, [:risk, :changed, :branch_heavy], nil, 8),
          high_risk_reason_count:
            nested(config, [:risk, :changed, :high_risk_reason_count], nil, 3)
        }
      },
      candidates: %Candidates{
        thresholds: %Candidates.Thresholds{
          mixed_effect_count:
            nested(config, [:candidates, :thresholds, :mixed_effect_count], nil, 2),
          branchy_function_branches:
            nested(config, [:candidates, :thresholds, :branchy_function_branches], nil, 8),
          high_risk_direct_callers:
            nested(config, [:candidates, :thresholds, :high_risk_direct_callers], nil, 4)
        },
        limits: %Candidates.Limits{
          per_kind: nested(config, [:candidates, :limits, :per_kind], nil, 20),
          representative_calls:
            nested(config, [:candidates, :limits, :representative_calls], nil, 10),
          representative_calls_per_edge:
            nested(config, [:candidates, :limits, :representative_calls_per_edge], nil, 3)
        }
      },
      checks: %Checks{
        baseline: nested(config, [:checks, :baseline], nil, nil),
        layer_coverage:
          normalize_layer_coverage(nested(config, [:checks, :layer_coverage], nil, nil))
      },
      clone_analysis: %CloneAnalysis{
        provider: nested(config, [:clone_analysis, :provider], nil, :ex_dna),
        min_mass: nested(config, [:clone_analysis, :min_mass], nil, 30),
        min_similarity: nested(config, [:clone_analysis, :min_similarity], nil, 1.0),
        max_clones: nested(config, [:clone_analysis, :max_clones], nil, 50)
      },
      smells: %Smells{
        strict: nested(config, [:smells, :strict], nil, false),
        custom_checks: nested(config, [:smells, :custom_checks], nil, []),
        fixed_shape_map: %Smells.FixedShapeMap{
          min_keys: nested(config, [:smells, :fixed_shape_map, :min_keys], nil, 3),
          min_occurrences: nested(config, [:smells, :fixed_shape_map, :min_occurrences], nil, 3),
          evidence_limit: nested(config, [:smells, :fixed_shape_map, :evidence_limit], nil, 10)
        },
        behaviour_candidate: %Smells.BehaviourCandidate{
          min_modules: nested(config, [:smells, :behaviour_candidate, :min_modules], nil, 3),
          min_callbacks: nested(config, [:smells, :behaviour_candidate, :min_callbacks], nil, 3),
          module_display_limit:
            nested(config, [:smells, :behaviour_candidate, :module_display_limit], nil, 8),
          callback_display_limit:
            nested(config, [:smells, :behaviour_candidate, :callback_display_limit], nil, 8)
        }
      }
    }
  end

  defp normalize_risk(%Risk{} = risk), do: %{risk | changed: risk.changed || %Risk.Changed{}}
  defp normalize_risk(_risk), do: %Risk{}

  defp normalize_candidates(%Candidates{} = candidates) do
    %{
      candidates
      | thresholds: candidates.thresholds || %Candidates.Thresholds{},
        limits: candidates.limits || %Candidates.Limits{}
    }
  end

  defp normalize_candidates(_candidates), do: %Candidates{}

  defp normalize_clone_analysis(%CloneAnalysis{} = clone_analysis), do: clone_analysis
  defp normalize_clone_analysis(_clone_analysis), do: %CloneAnalysis{}

  defp normalize_checks(%Checks{} = checks) do
    %{checks | layer_coverage: normalize_layer_coverage(checks.layer_coverage)}
  end

  defp normalize_checks(_checks), do: %Checks{}

  defp normalize_layer_coverage(%Checks.LayerCoverage{} = coverage), do: coverage

  defp normalize_layer_coverage(nil), do: nil

  defp normalize_layer_coverage(coverage) when is_list(coverage) do
    %Checks.LayerCoverage{
      require_all_modules: Keyword.get(coverage, :require_all_modules, false),
      forbid_multiple_matches: Keyword.get(coverage, :forbid_multiple_matches, false),
      ignore: Keyword.get(coverage, :ignore, [])
    }
  end

  defp normalize_layer_coverage(_coverage), do: nil

  defp normalize_smells(%Smells{} = smells) do
    %{
      smells
      | fixed_shape_map: smells.fixed_shape_map || %Smells.FixedShapeMap{},
        behaviour_candidate: smells.behaviour_candidate || %Smells.BehaviourCandidate{}
    }
  end

  defp normalize_smells(_smells) do
    %Smells{
      fixed_shape_map: %Smells.FixedShapeMap{},
      behaviour_candidate: %Smells.BehaviourCandidate{}
    }
  end

  def errors(config) when is_list(config) do
    if Keyword.keyword?(config) do
      unknown_key_errors(config) ++ shape_errors(config) ++ semantic_errors(config)
    else
      [%Error{path: [], message: "expected keyword list"}]
    end
  end

  def errors(_config), do: [%Error{path: [], message: "expected keyword list"}]

  defp unknown_key_errors(config) do
    config
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @top_level_keys))
    |> Enum.map(fn key ->
      %Error{path: [key], message: "Unknown .reach.exs key #{inspect(key)}"}
    end)
  end

  defp shape_errors(config) do
    []
    |> check(config, [:layers], &valid_layers?/1, "expected keyword list of layer: patterns")
    |> check(config, [:deps], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:deps, :forbidden],
      &valid_forbidden_deps?/1,
      "expected list of {from_layer, to_layer} or {from_layer, to_layer, opts}"
    )
    |> check(config, [:deps, :mode], &valid_deps_mode?/1, "expected :forbidlist or :allowlist")
    |> check(
      config,
      [:deps, :allowed],
      &valid_allowed_deps?/1,
      "expected keyword list of from_layer: [to_layers]"
    )
    |> check(config, [:calls], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:calls, :forbidden],
      &valid_forbidden_calls?/1,
      "expected list of {caller_patterns, call_patterns} or {caller_patterns, call_patterns, opts}"
    )
    |> check(config, [:effects], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:effects, :allowed],
      &valid_allowed_effects?/1,
      "expected list of {module_pattern, effects}"
    )
    |> check(
      config,
      [:effects, :by_layer],
      &valid_layer_effects?/1,
      "expected keyword list of layer: effects or layer: :any"
    )
    |> check(config, [:boundaries], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:boundaries, :public],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:boundaries, :internal],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:boundaries, :internal_callers],
      &valid_internal_callers?/1,
      "expected list of {internal_pattern, caller_patterns}"
    )
    |> check(config, [:tests], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:tests, :hints],
      &valid_test_hints?/1,
      "expected list of {path_glob, test_paths}"
    )
    |> check(config, [:source], &valid_group?/1, "expected keyword list")
    |> check(config, [:risk], &valid_group?/1, "expected keyword list")
    |> check(config, [:risk, :changed], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:risk, :changed, :many_direct_callers],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:risk, :changed, :wide_transitive_callers],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:risk, :changed, :branch_heavy],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:risk, :changed, :high_risk_reason_count],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(config, [:candidates], &valid_group?/1, "expected keyword list")
    |> check(config, [:clone_analysis], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:clone_analysis, :provider],
      &valid_clone_provider?/1,
      "expected :ex_dna or false"
    )
    |> check(
      config,
      [:clone_analysis, :min_mass],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:clone_analysis, :min_similarity],
      &valid_similarity?/1,
      "expected float between 0.0 and 1.0"
    )
    |> check(
      config,
      [:clone_analysis, :max_clones],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(config, [:checks], &valid_group?/1, "expected keyword list")
    |> check(config, [:checks, :baseline], &is_binary/1, "expected string")
    |> check(
      config,
      [:checks, :layer_coverage],
      &valid_layer_coverage?/1,
      "expected keyword list with require_all_modules, forbid_multiple_matches, and ignore"
    )
    |> check(config, [:smells], &valid_group?/1, "expected keyword list")
    |> check(config, [:smells, :strict], &valid_boolean?/1, "expected boolean")
    |> check(config, [:smells, :custom_checks], &valid_module_list?/1, "expected list of modules")
    |> check(config, [:smells, :fixed_shape_map], &valid_group?/1, "expected keyword list")
    |> check(config, [:smells, :behaviour_candidate], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:smells, :fixed_shape_map, :min_keys],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:smells, :fixed_shape_map, :min_occurrences],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:smells, :fixed_shape_map, :evidence_limit],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:smells, :behaviour_candidate, :min_modules],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:smells, :behaviour_candidate, :min_callbacks],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:smells, :behaviour_candidate, :module_display_limit],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:smells, :behaviour_candidate, :callback_display_limit],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(config, [:candidates, :thresholds], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:candidates, :thresholds, :mixed_effect_count],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:candidates, :thresholds, :branchy_function_branches],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:candidates, :thresholds, :high_risk_direct_callers],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(config, [:candidates, :limits], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:candidates, :limits, :per_kind],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:candidates, :limits, :representative_calls],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:candidates, :limits, :representative_calls_per_edge],
      &valid_positive_integer?/1,
      "expected positive integer"
    )
    |> check(
      config,
      [:source, :forbidden_modules],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:source, :forbidden_files],
      &valid_pattern_list?/1,
      "expected string or list of path globs"
    )
    |> check(
      config,
      [:forbidden_deps],
      &valid_forbidden_deps?/1,
      "expected list of {from_layer, to_layer} or {from_layer, to_layer, opts}"
    )
    |> check(
      config,
      [:allowed_effects],
      &valid_allowed_effects?/1,
      "expected list of {module_pattern, effects}"
    )
    |> check(
      config,
      [:forbidden_calls],
      &valid_forbidden_calls?/1,
      "expected list of {caller_patterns, call_patterns} or {caller_patterns, call_patterns, opts}"
    )
    |> check(
      config,
      [:public_api],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:internal],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:internal_callers],
      &valid_internal_callers?/1,
      "expected list of {internal_pattern, caller_patterns}"
    )
    |> check(
      config,
      [:test_hints],
      &valid_test_hints?/1,
      "expected list of {path_glob, test_paths}"
    )
    |> check(
      config,
      [:forbidden_modules],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:forbidden_files],
      &valid_pattern_list?/1,
      "expected string or list of path globs"
    )
    |> unknown_nested_key_errors(config, [:deps], [:forbidden, :mode, :allowed])
    |> unknown_nested_key_errors(config, [:calls], [:forbidden])
    |> unknown_nested_key_errors(config, [:effects], [:allowed, :by_layer])
    |> unknown_nested_key_errors(config, [:boundaries], [:public, :internal, :internal_callers])
    |> unknown_nested_key_errors(config, [:tests], [:hints])
    |> unknown_nested_key_errors(config, [:source], [:forbidden_modules, :forbidden_files])
    |> unknown_nested_key_errors(config, [:risk], [:changed])
    |> unknown_nested_key_errors(config, [:risk, :changed], [
      :many_direct_callers,
      :wide_transitive_callers,
      :branch_heavy,
      :high_risk_reason_count
    ])
    |> unknown_nested_key_errors(config, [:clone_analysis], [
      :provider,
      :min_mass,
      :min_similarity,
      :max_clones
    ])
    |> unknown_nested_key_errors(config, [:candidates], [:thresholds, :limits])
    |> unknown_nested_key_errors(config, [:candidates, :thresholds], [
      :mixed_effect_count,
      :branchy_function_branches,
      :high_risk_direct_callers
    ])
    |> unknown_nested_key_errors(config, [:candidates, :limits], [
      :per_kind,
      :representative_calls,
      :representative_calls_per_edge
    ])
    |> unknown_nested_key_errors(config, [:checks], [
      :baseline,
      :layer_coverage
    ])
    |> unknown_nested_key_errors(config, [:checks, :layer_coverage], [
      :require_all_modules,
      :forbid_multiple_matches,
      :ignore
    ])
    |> unknown_nested_key_errors(config, [:smells], [
      :strict,
      :custom_checks,
      :fixed_shape_map,
      :behaviour_candidate
    ])
    |> unknown_nested_key_errors(config, [:smells, :fixed_shape_map], [
      :min_keys,
      :min_occurrences,
      :evidence_limit
    ])
    |> unknown_nested_key_errors(config, [:smells, :behaviour_candidate], [
      :min_modules,
      :min_callbacks,
      :module_display_limit,
      :callback_display_limit
    ])
  end

  defp check(errors, config, path, validator, message) do
    case get_in_config(config, path) do
      :missing ->
        errors

      value ->
        if validator.(value), do: errors, else: [%Error{path: path, message: message} | errors]
    end
  end

  defp unknown_nested_key_errors(errors, config, path, allowed_keys) do
    case get_in_config(config, path) do
      value when is_list(value) -> nested_key_errors(value, path, allowed_keys) ++ errors
      _ -> errors
    end
  end

  defp nested_key_errors(value, path, allowed_keys) do
    if Keyword.keyword?(value) do
      value
      |> Keyword.keys()
      |> Enum.reject(&(&1 in allowed_keys))
      |> Enum.map(fn key ->
        %Error{path: path ++ [key], message: "Unknown .reach.exs key #{inspect(key)}"}
      end)
    else
      []
    end
  end

  defp nested(config, path, flat_key, default) do
    case get_in_config(config, path) do
      :missing -> Keyword.get(config, flat_key, default)
      value -> value
    end
  end

  defp get_in_config(config, [key]) do
    if Keyword.has_key?(config, key), do: Keyword.get(config, key), else: :missing
  end

  defp get_in_config(config, [key | rest]) do
    case get_in_config(config, [key]) do
      value when is_list(value) -> get_in_config(value, rest)
      :missing -> :missing
      _value -> :missing
    end
  end

  defp valid_group?(value), do: Keyword.keyword?(value)
  defp valid_boolean?(value), do: is_boolean(value)
  defp valid_module_list?(value) when is_list(value), do: Enum.all?(value, &is_atom/1)
  defp valid_module_list?(_value), do: false
  defp valid_positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_similarity?(value) when is_number(value), do: value >= 0.0 and value <= 1.0
  defp valid_similarity?(_value), do: false

  defp valid_clone_provider?(value), do: value in [:ex_dna, false, nil]

  defp valid_layers?(value) when is_list(value) do
    Enum.all?(value, fn
      {layer, patterns} when is_atom(layer) -> valid_pattern_list?(patterns)
      _ -> false
    end)
  end

  defp valid_layers?(_value), do: false

  defp valid_forbidden_deps?(value) when is_list(value) do
    Enum.all?(value, fn
      {from, to} when is_atom(from) and is_atom(to) ->
        true

      {from, to, opts} when is_atom(from) and is_atom(to) and is_list(opts) ->
        valid_pattern_list?(Keyword.get(opts, :except, [])) and
          valid_except_edges?(Keyword.get(opts, :except_edges, []))

      _ ->
        false
    end)
  end

  defp valid_forbidden_deps?(_value), do: false

  defp valid_deps_mode?(mode), do: mode in [:forbidlist, :allowlist]

  defp valid_allowed_deps?(value) when is_list(value) do
    Keyword.keyword?(value) and
      Enum.all?(value, fn
        {from, tos} when is_atom(from) and is_list(tos) -> Enum.all?(tos, &is_atom/1)
        _ -> false
      end)
  end

  defp valid_allowed_deps?(_value), do: false

  defp valid_layer_coverage?(value) when is_list(value) do
    Keyword.keyword?(value) and
      valid_boolean?(Keyword.get(value, :require_all_modules, false)) and
      valid_boolean?(Keyword.get(value, :forbid_multiple_matches, false)) and
      valid_pattern_list?(Keyword.get(value, :ignore, []))
  end

  defp valid_layer_coverage?(_value), do: false

  defp valid_except_edges?(value) when is_list(value) do
    Enum.all?(value, fn
      {caller_pattern, callee_pattern}
      when is_binary(caller_pattern) and is_binary(callee_pattern) ->
        true

      _ ->
        false
    end)
  end

  defp valid_except_edges?(_value), do: false

  defp valid_layer_effects?(value) when is_list(value) do
    Keyword.keyword?(value) and
      Enum.all?(value, fn
        {layer, :any} when is_atom(layer) ->
          true

        {layer, effects} when is_atom(layer) and is_list(effects) ->
          Enum.all?(effects, &is_atom/1)

        _ ->
          false
      end)
  end

  defp valid_layer_effects?(_value), do: false

  defp valid_allowed_effects?(value) when is_list(value) do
    Enum.all?(value, fn
      {pattern, effects} when is_binary(pattern) and is_list(effects) ->
        Enum.all?(effects, &is_atom/1)

      _ ->
        false
    end)
  end

  defp valid_allowed_effects?(_value), do: false

  defp valid_forbidden_calls?(value) when is_list(value) do
    Enum.all?(value, fn
      {caller_patterns, call_patterns} ->
        valid_pattern_list?(caller_patterns) and valid_pattern_list?(call_patterns)

      {caller_patterns, call_patterns, opts} when is_list(opts) ->
        valid_pattern_list?(caller_patterns) and valid_pattern_list?(call_patterns) and
          valid_pattern_list?(Keyword.get(opts, :except, []))

      _ ->
        false
    end)
  end

  defp valid_forbidden_calls?(_value), do: false

  defp valid_pattern_list?(value) when is_binary(value), do: true
  defp valid_pattern_list?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp valid_pattern_list?(_value), do: false

  defp valid_internal_callers?(value) when is_list(value) do
    Enum.all?(value, fn
      {internal_pattern, caller_patterns} when is_binary(internal_pattern) ->
        valid_pattern_list?(caller_patterns)

      _ ->
        false
    end)
  end

  defp valid_internal_callers?(_value), do: false

  defp valid_test_hints?(value) when is_list(value) do
    Enum.all?(value, fn
      {pattern, tests} when is_binary(pattern) and is_list(tests) ->
        Enum.all?(tests, &is_binary/1)

      _ ->
        false
    end)
  end

  defp valid_test_hints?(_value), do: false

  defp semantic_errors(config) do
    layers = declared_layers(config)

    unknown_forbidden_dep_layer_errors(config, layers) ++
      unknown_allowed_dep_layer_errors(config, layers) ++
      unknown_effect_layer_errors(config, layers) ++
      allowlist_conflict_errors(config)
  end

  defp declared_layers(config) do
    case get_in_config(config, [:layers]) do
      layers when is_list(layers) ->
        if Keyword.keyword?(layers), do: MapSet.new(Keyword.keys(layers)), else: MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp unknown_forbidden_dep_layer_errors(config, layers) do
    case nested(config, [:deps, :forbidden], :forbidden_deps, []) do
      rules when is_list(rules) ->
        Enum.flat_map(rules, fn
          {from, to} -> unknown_layer_errors([from, to], layers, [:deps, :forbidden])
          {from, to, _opts} -> unknown_layer_errors([from, to], layers, [:deps, :forbidden])
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp unknown_effect_layer_errors(config, layers) do
    case nested(config, [:effects, :by_layer], nil, []) do
      policies when is_list(policies) ->
        policies
        |> Keyword.keys()
        |> unknown_layer_errors(layers, [:effects, :by_layer])

      _ ->
        []
    end
  end

  defp unknown_allowed_dep_layer_errors(config, layers) do
    case nested(config, [:deps, :allowed], nil, []) do
      rules when is_list(rules) ->
        Enum.flat_map(rules, fn
          {from, tos} when is_list(tos) ->
            unknown_layer_errors([from | tos], layers, [:deps, :allowed])

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp unknown_layer_errors(layer_refs, layers, path) do
    layer_refs
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(layers, &1))
    |> Enum.map(fn layer ->
      %Error{path: path, message: unknown_layer_message(layer, layers)}
    end)
  end

  defp unknown_layer_message(layer, layers) do
    known = layers |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
    "unknown layer #{inspect(layer)}. Known layers: #{known}"
  end

  defp allowlist_conflict_errors(config) do
    with :allowlist <- get_in_config(config, [:deps, :mode]),
         forbidden when forbidden not in [nil, []] <-
           nested(config, [:deps, :forbidden], :forbidden_deps, []) do
      [
        %Error{
          path: [:deps],
          message: "deps.mode :allowlist cannot be combined with deps.forbidden"
        }
      ]
    else
      _ -> []
    end
  end
end
