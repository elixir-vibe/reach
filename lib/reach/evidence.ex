defmodule Reach.Evidence do
  @moduledoc """
  Reusable evidence providers consumed by smells, checks, and refactoring candidates.

  Evidence modules collect facts and signals. They do not decide whether
  something is a user-facing finding; smell and check modules own that policy.
  """

  @ast_providers [
    Reach.Evidence.StandardLibraryBypass,
    Reach.Evidence.MapContract
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

  defp ast_provider?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :family, 0) and
      function_exported?(module, :kinds, 0) and
      function_exported?(module, :collect_ast, 1)
  end
end
