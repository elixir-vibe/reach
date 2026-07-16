defmodule Reach.Smell.Check.Evidence do
  @moduledoc "Promotes one AST evidence provider into an explicitly registered smell check."

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use Reach.Smell.Check.AST

      alias Reach.Smell.Finding

      @evidence_provider provider

      @impl true
      def kinds, do: @evidence_provider.kinds()

      defp scan_ast(ast, file) do
        ast
        |> @evidence_provider.collect_ast()
        |> Enum.map(fn evidence ->
          Finding.new(
            kind: evidence.kind,
            message: evidence.message,
            location: %{
              file: file,
              line: evidence.meta[:line],
              column: evidence.meta[:column]
            },
            evidence: evidence.replacement,
            confidence: evidence.confidence
          )
        end)
      end
    end
  end
end
