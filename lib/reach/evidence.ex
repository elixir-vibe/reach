defmodule Reach.Evidence do
  @moduledoc """
  Reusable evidence providers consumed by smells, checks, and refactoring candidates.

  Evidence modules collect facts and signals. They do not decide whether
  something is a user-facing finding; smell and check modules own that policy.
  """

  alias Reach.Evidence.{
    CloneAnalysis,
    ExternalDataBoundary,
    NilParameter,
    ParameterShape,
    RepresentationOverlap,
    ReturnContract,
    TotalFunctionLaundering
  }

  @ast_providers [
    Reach.Evidence.StandardLibraryBypass,
    Reach.Evidence.MapContract,
    Reach.Evidence.TotalFunctionLaundering
  ]

  @doc "Returns AST evidence providers available for the configured plugins."
  def ast_providers(plugins \\ []) do
    (@ast_providers ++ Reach.Plugin.evidence_providers(plugins))
    |> Enum.filter(&ast_provider?/1)
    |> Enum.uniq()
  end

  @doc "Returns AST evidence providers matching a family or all providers."
  def ast_providers_for(:all, plugins), do: ast_providers(plugins)

  def ast_providers_for(family, plugins) when is_atom(family) do
    Enum.filter(ast_providers(plugins), &(&1.family() == family))
  end

  @doc "Returns decoded external values crossing storage or process boundaries."
  def external_data_boundaries(project), do: ExternalDataBoundary.collect_project(project)

  @doc "Returns terminal return-shape evidence grouped by function."
  def return_contracts(project), do: ReturnContract.collect_project(project)

  @doc "Returns accepted-domain fallback evidence from private parsers."
  def total_function_laundering(project), do: TotalFunctionLaundering.collect_project(project)

  @doc "Returns nil-capable parameter uses and guard-dominance evidence."
  def nil_parameters(project), do: NilParameter.collect_project(project)

  @doc "Returns near-equivalent struct and bare-map representations across modules."
  def representation_overlaps(project, opts \\ []),
    do: RepresentationOverlap.collect_project(project, opts)

  @doc "Returns map-shape variation flowing into function parameters."
  def parameter_shapes(project), do: ParameterShape.collect_project(project)

  @doc "Returns generic project-to-dependency reimplementation evidence."
  def dependency_bypass(project, config \\ []) do
    CloneAnalysis.dependency_bypass(project, config)
  end

  defp ast_provider?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :family, 0) and
      function_exported?(module, :kinds, 0) and
      function_exported?(module, :collect_ast, 1)
  end
end
