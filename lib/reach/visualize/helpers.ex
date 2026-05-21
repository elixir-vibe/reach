defmodule Reach.Visualize.Helpers do
  @moduledoc "Shared helpers for source extraction and line mapping."

  # ── IR helpers ──

  def clause_pattern(clause) do
    clause.children
    |> Enum.take_while(fn c ->
      c.meta[:binding_role] == :definition or
        c.type in [:literal, :tuple, :map, :list, :struct, :var]
    end)
    |> Enum.map_join(", ", &ir_label/1)
    |> case do
      "" -> "_"
      s -> s
    end
  end

  def ir_label(%{meta: %{origin: %{label: label}}}) when is_binary(label), do: label
  def ir_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  def ir_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  def ir_label(%{type: :tuple}), do: "{...}"
  def ir_label(%{type: :map}), do: "%{...}"
  def ir_label(%{type: :binary_op, meta: %{operator: op}}), do: to_string(op)
  def ir_label(%{type: :unary_op, meta: %{operator: op}}), do: to_string(op)
  def ir_label(%{type: :pin}), do: "^"
  def ir_label(%{type: :guard}), do: "guard"
  def ir_label(%{type: :cons}), do: "[head | tail]"
  def ir_label(%{type: :generator}), do: "<-"
  def ir_label(%{type: :filter}), do: "filter"
  def ir_label(%{type: :module_def, meta: %{name: name}}), do: "defmodule #{inspect(name)}"
  def ir_label(%{type: type}), do: to_string(type)

  def render_pattern(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  def render_pattern(%{type: :var, meta: %{name: name}}), do: to_string(name)

  def render_pattern(%{type: :tuple, children: children}) do
    inner = Enum.map_join(children, ", ", &render_pattern/1)
    "{#{inner}}"
  end

  def render_pattern(%{type: :map, children: children}) do
    pairs = Enum.map_join(children, ", ", &render_map_field/1)
    "%{#{pairs}}"
  end

  def render_pattern(%{type: :list, children: children}) do
    inner = Enum.map_join(children, ", ", &render_pattern/1)
    "[#{inner}]"
  end

  def render_pattern(%{type: :struct, children: children, meta: meta}) do
    name = if meta[:name], do: inspect(meta[:name]), else: ""
    fields = Enum.map_join(children, ", ", &render_map_field/1)
    "%#{name}{#{fields}}"
  end

  def render_pattern(%{type: :pin, children: [inner]}), do: "^#{render_pattern(inner)}"
  def render_pattern(%{type: :pin}), do: "^_"

  def render_pattern(%{type: :binary_op, meta: %{operator: op}, children: [left, right]}) do
    "#{render_pattern(left)} #{op} #{render_pattern(right)}"
  end

  def render_pattern(%{type: :unary_op, meta: %{operator: op}, children: [inner]}) do
    "#{op}#{render_pattern(inner)}"
  end

  def render_pattern(%{type: :cons, children: [head, tail]}) do
    "[#{render_pattern(head)} | #{render_pattern(tail)}]"
  end

  def render_pattern(%{type: :guard, children: [inner]}), do: render_pattern(inner)
  def render_pattern(%{type: :guard}), do: "true"

  def render_pattern(%{type: :generator, children: [pattern, _expr]}) do
    "#{render_pattern(pattern)} <- ..."
  end

  def render_pattern(%{type: :filter, children: [inner]}), do: render_pattern(inner)

  def render_pattern(%{type: :module_def, meta: %{name: name}}) do
    "defmodule #{inspect(name)}"
  end

  def render_pattern(%{type: type}), do: to_string(type)

  defp render_map_field(%{
         type: :map_field,
         children: [%{type: :literal, meta: %{value: key}}, val]
       }) do
    "#{key}: #{render_pattern(val)}"
  end

  defp render_map_field(%{type: :map_field, children: [key, _val]}) do
    "#{render_pattern(key)}: ..."
  end

  defp render_map_field(node), do: render_pattern(node)
end
