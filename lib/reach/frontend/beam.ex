defmodule Reach.Frontend.BEAM do
  @moduledoc "BEAM bytecode frontend for analyzing compiled .beam files."
  alias Reach.IR.Counter

  alias Reach.Frontend.Erlang

  @spec from_bytecode(binary(), keyword()) :: {:ok, [Reach.IR.Node.t()]} | {:error, term()}
  def from_bytecode(bytecode, opts \\ []) when is_binary(bytecode) do
    with {:error, _} <- from_abstract_code(bytecode, opts),
         {:error, _} <- from_debug_info(bytecode, opts) do
      {:error, :no_debug_info}
    end
  end

  @spec from_module(module(), keyword()) :: {:ok, [Reach.IR.Node.t()]} | {:error, term()}
  def from_module(module, opts \\ []) when is_atom(module) do
    case :code.which(module) do
      :non_existing ->
        {:error, :module_not_found}

      path when is_list(path) or is_binary(path) ->
        case File.read(path) do
          {:ok, bytecode} ->
            from_bytecode(bytecode, Keyword.put_new(opts, :file, to_string(path)))

          {:error, reason} ->
            {:error, reason}
        end

      _preloaded_or_cover_compiled ->
        {:error, :bytecode_unavailable}
    end
  end

  @spec from_compiled_string(String.t(), keyword()) ::
          {:ok, [Reach.IR.Node.t()]} | {:error, term()}
  def from_compiled_string(source, opts \\ []) do
    tmp_dir = Path.join(System.tmp_dir!(), "reach_beam_#{:erlang.unique_integer([:positive])}")

    try do
      File.mkdir_p!(tmp_dir)
      tmp_file = Path.join(tmp_dir, "source.ex")
      File.write!(tmp_file, source)

      modules = compile_with_debug_info(tmp_file, tmp_dir)

      nodes =
        Enum.flat_map(modules, fn mod ->
          beam_path = Path.join(tmp_dir, Atom.to_string(mod) <> ".beam")

          case File.read(beam_path) do
            {:ok, bytecode} ->
              case from_bytecode(bytecode, opts) do
                {:ok, n} -> n
                {:error, _} -> []
              end

            {:error, _} ->
              []
          end
        end)

      {:ok, nodes}
    rescue
      e in [ArgumentError, ErlangError, File.Error, MatchError] ->
        {:error, {e.__struct__, Exception.message(e)}}
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp compile_with_debug_info(tmp_file, tmp_dir) do
    prev = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      case Kernel.ParallelCompiler.compile_to_path([tmp_file], tmp_dir, return_diagnostics: true) do
        {:ok, modules, _diagnostics} -> modules
        {:error, errors, _diagnostics} -> raise "compilation failed: #{inspect(errors)}"
      end
    after
      Code.put_compiler_option(:debug_info, prev)
    end
  end

  @spec from_compiled_modules([{module(), binary()}], keyword()) :: {:ok, [Reach.IR.Node.t()]}
  def from_compiled_modules(compiled, opts \\ []) do
    nodes =
      Enum.flat_map(compiled, fn {_module, bytecode} ->
        case from_bytecode(bytecode, opts) do
          {:ok, n} -> n
          {:error, _} -> []
        end
      end)

    {:ok, nodes}
  end

  defp from_abstract_code(bytecode, opts) do
    case :beam_lib.chunks(bytecode, [:abstract_code]) do
      {:ok, {module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        opts = opts |> Keyword.put_new(:file, to_string(module)) |> Keyword.put(:module, module)
        translate_forms(forms, opts)

      _ ->
        {:error, :no_abstract_code}
    end
  end

  defp from_debug_info(bytecode, opts) do
    case :beam_lib.chunks(bytecode, [:debug_info]) do
      {:ok, {module, [{:debug_info, {:debug_info_v1, backend, data}}]}} ->
        case backend.debug_info(:erlang_v1, module, data, []) do
          {:ok, forms} ->
            opts =
              opts |> Keyword.put_new(:file, to_string(module)) |> Keyword.put(:module, module)

            translate_forms(forms, opts)

          _ ->
            {:error, :debug_info_decode_failed}
        end

      _ ->
        {:error, :no_debug_info}
    end
  end

  defp translate_forms(forms, opts) do
    file = Keyword.get(opts, :file, "nofile")
    module = Keyword.get(opts, :module)
    counter = Counter.new()

    nodes =
      forms
      |> select_function_forms(opts)
      |> Enum.reject(fn
        {:eof, _} -> true
        {:attribute, _, :file, _} -> true
        {:function, _, :__info__, _, _} -> true
        {:function, _, :module_info, _, _} -> true
        _ -> false
      end)
      |> Enum.map(&Erlang.translate_form(&1, counter, file))
      |> Enum.map(&put_owner_module(&1, module))

    {:ok, nodes}
  end

  defp select_function_forms(forms, opts) do
    case Keyword.get(opts, :functions) do
      nil -> forms
      targets when is_list(targets) -> reachable_function_forms(forms, targets, opts)
    end
  end

  defp reachable_function_forms(forms, targets, opts) do
    function_forms =
      Map.new(forms, fn
        {:function, _line, name, arity, _clauses} = form -> {{name, arity}, form}
        other -> {{:non_function, :erlang.phash2(other)}, other}
      end)

    max_functions = Keyword.get(opts, :max_functions, map_size(function_forms))

    targets
    |> collect_reachable_forms(function_forms, MapSet.new(), max_functions)
    |> Enum.map(&Map.fetch!(function_forms, &1))
  end

  defp collect_reachable_forms([], _forms, seen, _remaining), do: MapSet.to_list(seen)
  defp collect_reachable_forms(_pending, _forms, seen, 0), do: MapSet.to_list(seen)

  defp collect_reachable_forms([key | pending], forms, seen, remaining) do
    cond do
      MapSet.member?(seen, key) ->
        collect_reachable_forms(pending, forms, seen, remaining)

      not Map.has_key?(forms, key) ->
        collect_reachable_forms(pending, forms, seen, remaining)

      true ->
        form = Map.fetch!(forms, key)
        callees = local_function_calls(form)

        collect_reachable_forms(
          pending ++ callees,
          forms,
          MapSet.put(seen, key),
          remaining - 1
        )
    end
  end

  defp local_function_calls(form) do
    form
    |> collect_local_function_calls(MapSet.new())
    |> MapSet.to_list()
  end

  defp collect_local_function_calls({:call, _line, {:atom, _, name}, args}, calls)
       when is_list(args) do
    Enum.reduce(args, MapSet.put(calls, {name, length(args)}), &collect_local_function_calls/2)
  end

  defp collect_local_function_calls(tuple, calls) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(calls, &collect_local_function_calls/2)
  end

  defp collect_local_function_calls(list, calls) when is_list(list),
    do: Enum.reduce(list, calls, &collect_local_function_calls/2)

  defp collect_local_function_calls(_other, calls), do: calls

  defp put_owner_module(%Reach.IR.Node{} = node, module) do
    meta =
      case node do
        %{type: :function_def} ->
          Map.put(node.meta, :module, module)

        %{type: :call, meta: %{kind: kind}} when kind in [:local, :fun_ref] ->
          node.meta
          |> Map.put(:owner_module, module)
          |> Map.put_new(:module, module)

        _other ->
          node.meta
      end

    %{node | meta: meta, children: Enum.map(node.children, &put_owner_module(&1, module))}
  end
end
