defmodule Reach.Plugin.LowerElixirASTTest do
  use ExUnit.Case, async: true

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.Source.{Origin, Span}

  defmodule LoweringPlugin do
    @behaviour Reach.Plugin

    @impl true
    def analyze(_all_nodes, _opts), do: []

    @impl true
    def lower_elixir_ast({:dsl_if, meta, [condition, body]}, opts) do
      span = %Span{file: opts[:file], start_line: meta[:line], start_col: meta[:column] || 1}

      ast =
        {:if,
         [
           line: meta[:line],
           column: meta[:column],
           reach: %Origin{
             language: :test_dsl,
             kind: :if,
             label: "dsl_if",
             span: span,
             plugin: __MODULE__,
             generated?: true
           }
         ], [condition, [do: body]]}

      {:ok, ast}
    end

    def lower_elixir_ast(_ast, _opts), do: :ignore
  end

  test "plugins lower local Elixir AST before IR translation" do
    source = """
    defmodule Demo do
      def render(assigns) do
        dsl_if(assigns.ok, :visible)
      end
    end
    """

    assert {:ok, nodes} =
             ElixirFrontend.parse(source, file: "demo.ex", plugins: [LoweringPlugin])

    lowered_case =
      nodes
      |> flatten()
      |> Enum.find(&(&1.type == :case and &1.meta[:origin]))

    assert lowered_case.meta.origin.label == "dsl_if"
    assert lowered_case.meta.origin.language == :test_dsl
    assert lowered_case.source_span.file == "demo.ex"
    assert lowered_case.source_span.start_line == 3
  end

  defp flatten(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &flatten/1)
  defp flatten(%{children: children} = node), do: [node | flatten(children)]
end
