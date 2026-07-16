defmodule ReachCalibration.Config do
  @moduledoc "Validated configuration for reproducible Reach corpus calibration."

  @default_candidate_limit 5_000
  @default_seed "reach-calibration-v1"

  @schema NimbleOptions.new!(
            base_url: [type: :string, default: "http://localhost:4200"],
            limit: [type: :pos_integer, default: 25],
            output: [type: :string, default: "exograph-calibration-results.json"],
            labels: [type: {:or, [:string, nil]}, default: nil],
            paths: [type: {:list, :string}, default: []],
            kinds: [type: {:list, :atom}, default: []],
            candidate_limit: [type: :pos_integer, default: @default_candidate_limit],
            seed: [type: :string, default: @default_seed],
            help: [type: :boolean, default: false]
          )

  defstruct base_url: "http://localhost:4200",
            limit: 25,
            output: "exograph-calibration-results.json",
            labels: nil,
            paths: [],
            kinds: [],
            candidate_limit: @default_candidate_limit,
            seed: @default_seed,
            help: false

  @type t :: %__MODULE__{
          base_url: String.t(),
          limit: pos_integer(),
          output: Path.t(),
          labels: Path.t() | nil,
          paths: [String.t()],
          kinds: [atom()],
          candidate_limit: pos_integer(),
          seed: String.t(),
          help: boolean()
        }

  def default_seed, do: @default_seed

  def new!(opts) do
    opts
    |> NimbleOptions.validate!(@schema)
    |> then(&struct!(__MODULE__, &1))
  end

  def runner_options(%__MODULE__{} = config) do
    [
      base_url: config.base_url,
      limit: config.limit,
      kinds: kinds(config.kinds),
      labels: config.labels,
      seed: config.seed
    ]
    |> put_optional(:paths, non_empty(config.paths))
    |> put_optional(:candidate_limit, config.candidate_limit)
  end

  defp kinds([]), do: nil
  defp kinds(kinds), do: MapSet.new(kinds)
  defp non_empty([]), do: nil
  defp non_empty(values), do: values
  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)
end
