defmodule Reach.Analysis do
  @moduledoc "Shared analysis helpers for project-wide queries."

  alias Reach.IR.Node

  @effect_boundary_callbacks [
    {:start, 2},
    {:init, 1},
    {:handle_call, 3},
    {:handle_cast, 2},
    {:handle_info, 2},
    {:handle_continue, 2},
    {:terminate, 2},
    {:code_change, 3},
    {:mount, 3},
    {:handle_event, 3},
    {:handle_params, 3},
    {:start_link, 1},
    {:child_spec, 1},
    {:perform, 1},
    {:handle_batch, 1},
    {:handle_batch, 2}
  ]

  def expected_effect_boundary?(func) do
    {func.meta[:name], func.meta[:arity]} in @effect_boundary_callbacks or
      mix_task_module?(func.meta[:module]) or
      mix_task_file?(func.source_span)
  end

  defp mix_task_module?(nil), do: false

  defp mix_task_module?(module) when is_atom(module) do
    match?(["Mix", "Tasks" | _], Module.split(module))
  rescue
    ArgumentError -> false
  end

  defp mix_task_module?(_module), do: false

  defp mix_task_file?(nil), do: false
  defp mix_task_file?(%{file: file}), do: String.starts_with?(file || "", "lib/mix/tasks/")

  def data_edge?(%Graph.Edge{label: {:data, _}}), do: true

  def data_edge?(%Graph.Edge{label: label})
      when label in [:parameter_in, :parameter_out, :summary],
      do: true

  def data_edge?(_edge), do: false

  def call_target(%Node{children: [target | _]}) do
    case target do
      %Node{type: :literal, meta: %{value: mod}} when is_atom(mod) ->
        mod

      %Node{type: :var, meta: %{name: name}} ->
        name

      %Node{type: :call, meta: %{function: :__aliases__}, children: parts} ->
        module_alias(parts)

      _ ->
        nil
    end
  end

  def call_target(_node), do: nil

  def module_alias(parts) do
    atoms =
      Enum.map(parts, fn
        %{type: :literal, meta: %{value: value}} when is_atom(value) -> value
        _node -> nil
      end)

    if Enum.all?(atoms, & &1), do: Module.concat(atoms)
  end

  def location(%{source_span: %{file: file, start_line: line}}), do: "#{file}:#{line}"
  def location(%{source_span: %{start_line: line}}), do: "line #{line}"
  def location(_node), do: "unknown"
end
