defmodule Reach.Plugins.LiveView.HEExEngine do
  @moduledoc false

  @behaviour EEx.Engine

  @impl true
  def init(opts) do
    %{parts: [], caller: opts[:caller]}
  end

  @impl true
  def handle_begin(_state) do
    %{parts: []}
  end

  @impl true
  def handle_end(state) do
    parts = Enum.reverse(state.parts)

    case parts do
      [] -> :ok
      [single] -> single
      _ -> {:__block__, [], parts}
    end
  end

  def handle_end(state, _opts), do: handle_end(state)

  @impl true
  def handle_body(state) do
    handle_end(state)
  end

  def handle_body(state, _opts) do
    handle_end(state)
  end

  @impl true
  def handle_text(state, meta, text) do
    if String.trim(to_string(text)) == "" do
      state
    else
      append(state, text_ast(text, meta))
    end
  end

  @impl true
  def handle_expr(state, _marker, ast) do
    append(state, ast)
  end

  defp append(state, ast), do: %{state | parts: [ast | state.parts]}

  defp text_ast(text, meta) when is_list(meta) do
    {:__block__, meta, [to_string(text)]}
  end

  defp text_ast(text, _meta), do: to_string(text)
end
