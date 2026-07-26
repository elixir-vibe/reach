defmodule Reach.Check.AnalysisScope do
  @moduledoc """
  Describes the source set used by a Reach check.

  The file count is informational. Scope compatibility is based on the source
  origin, Mix environment, and configured roots so normal file additions and
  removals do not invalidate a baseline.
  """

  @derive JSON.Encoder
  @enforce_keys [:source, :source_roots, :file_count]
  defstruct [:mix_env, :source, :source_roots, :file_count]

  @type t :: %__MODULE__{
          mix_env: String.t() | nil,
          source: String.t(),
          source_roots: [Path.t()],
          file_count: non_neg_integer()
        }

  def new(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      mix_env: attrs |> Map.get(:mix_env) |> normalize_env(),
      source: attrs |> Map.fetch!(:source) |> to_string(),
      source_roots: attrs |> Map.fetch!(:source_roots) |> normalize_paths(),
      file_count: Map.fetch!(attrs, :file_count)
    }
  end

  def from_map(%__MODULE__{} = scope), do: scope

  def from_map(data) when is_map(data) do
    new(
      mix_env: field(data, :mix_env),
      source: field(data, :source),
      source_roots: field(data, :source_roots, []),
      file_count: field(data, :file_count, 0)
    )
  end

  def compatible?(%__MODULE__{} = left, %__MODULE__{} = right) do
    identity(left) == identity(right)
  end

  def describe(%__MODULE__{} = scope) do
    env = if scope.mix_env, do: "MIX_ENV=#{scope.mix_env}", else: "explicit paths"
    roots = if scope.source_roots == [], do: "(none)", else: Enum.join(scope.source_roots, ", ")
    "#{env}; roots=#{roots}; files=#{scope.file_count}"
  end

  defp identity(scope), do: {scope.source, scope.mix_env, scope.source_roots}

  defp normalize_env(nil), do: nil
  defp normalize_env(env), do: to_string(env)

  defp normalize_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.map(&portable_path/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp portable_path(path) do
    path
    |> Path.expand()
    |> Path.relative_to_cwd()
  end

  defp field(map, key, default \\ nil),
    do: Map.get(map, key) || Map.get(map, to_string(key), default)
end
