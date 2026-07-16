defmodule Reach.Trace.Pattern do
  @moduledoc "Plugin-dispatched trace matchers and named trace presets."

  alias Reach.IR.Node
  alias Reach.Trace.Pattern.Preset

  @structured_extensions ~w(.xml .html .htm .heex .eex .ex .exs .rs)
  @file_read_functions [:read, :read!, :stream!]
  @regex_functions [:run, :scan, :replace, :match?]

  def compile(pattern, plugins \\ []) do
    Reach.Plugin.trace_pattern(plugins, pattern) || compile_generic(pattern)
  end

  @doc "Resolves a plugin-owned or generic named trace preset."
  @spec preset(String.t(), [module()]) :: {:ok, Preset.t()} | :error
  def preset(pattern, plugins \\ []) do
    case Reach.Plugin.trace_preset(plugins, pattern) || generic_preset(pattern) do
      %Preset{} = preset -> {:ok, preset}
      nil -> :error
    end
  end

  defp compile_generic("System.cmd") do
    fn node ->
      node.type == :call and node.meta[:module] == System and node.meta[:function] == :cmd
    end
  end

  defp compile_generic(pattern) do
    fn
      %{type: :var, meta: %{name: name}} -> to_string(name) == pattern
      %{type: :call, meta: meta} -> to_string(meta[:function] || "") =~ pattern
      _node -> false
    end
  end

  defp generic_preset("regex-on-structured") do
    %Preset{
      name: "regex-on-structured",
      from: "structured file input",
      to: "regex/string parser",
      routes: [
        %{source: &structured_file_source?/1, sink: &regex_sink?/1},
        %{source: &file_source?/1, sink: &structure_shaped_regex_sink?/1}
      ]
    }
  end

  defp generic_preset(_pattern), do: nil

  defp structured_file_source?(%Node{} = node) do
    file_source?(node) and structured_path?(List.first(node.children))
  end

  defp structured_file_source?(_node), do: false

  defp file_source?(%Node{type: :call, meta: meta}) do
    meta[:module] == File and meta[:function] in @file_read_functions
  end

  defp file_source?(_node), do: false

  defp structured_path?(%Node{type: :literal, meta: %{value: path}}) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> then(&(&1 in @structured_extensions))
  end

  defp structured_path?(_node), do: false

  defp regex_sink?(%Node{type: :call, meta: meta} = node) do
    (meta[:module] == Regex and meta[:function] in @regex_functions) or
      regex_match_operator?(node) or regex_string_split?(node)
  end

  defp regex_sink?(_node), do: false

  defp structure_shaped_regex_sink?(%Node{} = node) do
    regex_sink?(node) and
      node
      |> regex_argument()
      |> regex_literal_source()
      |> structure_shaped_regex?()
  end

  defp structure_shaped_regex_sink?(_node), do: false

  defp regex_match_operator?(%Node{meta: %{module: nil, function: :=~}, children: children}) do
    Enum.any?(children, &regex_literal?/1)
  end

  defp regex_match_operator?(_node), do: false

  defp regex_string_split?(%Node{meta: %{module: String, function: :split}, children: children}) do
    children |> Enum.drop(1) |> Enum.any?(&regex_literal?/1)
  end

  defp regex_string_split?(_node), do: false

  defp regex_argument(%Node{meta: %{module: Regex}, children: [regex | _]}), do: regex

  defp regex_argument(%Node{meta: %{module: nil, function: :=~}, children: children}),
    do: Enum.find(children, &regex_literal?/1)

  defp regex_argument(%Node{meta: %{module: String, function: :split}, children: children}),
    do: children |> Enum.drop(1) |> Enum.find(&regex_literal?/1)

  defp regex_argument(_node), do: nil

  defp regex_literal?(%Node{type: :call, meta: %{module: nil, function: :sigil_r}}), do: true
  defp regex_literal?(_node), do: false

  defp regex_literal_source(%Node{} = regex) do
    regex
    |> literal_descendants()
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp regex_literal_source(_node), do: nil

  defp literal_descendants(%Node{type: :literal, meta: %{value: value}}), do: [value]

  defp literal_descendants(%Node{children: children}) do
    Enum.flat_map(children, &literal_descendants/1)
  end

  defp structure_shaped_regex?(source) when is_binary(source) do
    String.contains?(source, ["defmodule", "defstruct", "fn\\s"]) or
      Regex.match?(~r/<(?:[A-Za-z]|\/|\?xml|!DOCTYPE)/, source)
  end

  defp structure_shaped_regex?(_source), do: false
end
