defmodule Reach.Smell.Check do
  @moduledoc "Behaviour and shared helpers for IR-based smell checks."

  @callback run(Reach.Project.t()) :: [map()]
  @callback kinds() :: [atom()]

  @optional_callbacks kinds: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour Reach.Smell.Check

      alias Reach.IR
      alias Reach.Smell.{Finding, Helpers}

      def run(project) do
        project
        |> Helpers.function_defs()
        |> Enum.flat_map(&findings/1)
      end

      defp sourced_nodes(function) do
        function
        |> IR.all_nodes()
        |> Enum.filter(& &1.source_span)
      end

      defp finding(kind, message, node) do
        Finding.new(
          kind: kind,
          message: message,
          location: Helpers.location(node),
          source_range: node.source_span
        )
      end

      defoverridable run: 1
    end
  end
end
