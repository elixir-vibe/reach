defmodule Reach.Effects.Dependency do
  @moduledoc false

  alias Reach.{Effects, Frontend, IR}
  alias Reach.IR.Node

  @cache :reach_dependency_effect_cache
  @inference_key {__MODULE__, :inference}
  @max_dependency_functions 100
  @inference_plugins [__MODULE__]

  @spec classify(module(), atom(), non_neg_integer()) :: Effects.effect() | nil
  def classify(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    if Process.get(@inference_key) do
      nil
    else
      key = {module, function, arity}

      module
      |> fetch_or_build(key)
      |> case do
        :unknown -> nil
        effect -> effect
      end
    end
  end

  def classify(_module, _function, _arity), do: nil

  defp fetch_or_build(module, key) do
    ensure_cache()

    case cached_effect(module, key) do
      {:ok, effect} -> effect
      :miss -> build_locked(module, key)
    end
  rescue
    ArgumentError -> nil
  end

  defp cached_effect(module, key) do
    case :ets.lookup(@cache, module) do
      [{^module, summary}] ->
        case Map.fetch(summary, key) do
          {:ok, effect} -> {:ok, effect}
          :error -> :miss
        end

      [] ->
        :miss
    end
  end

  defp build_locked(module, key) do
    :global.trans({{__MODULE__, module}, self()}, fn ->
      case cached_effect(module, key) do
        {:ok, effect} -> effect
        :miss -> build_and_cache(module, key)
      end
    end)
  end

  defp build_and_cache(module, {module, function, arity} = key) do
    inferred = build(module, function, arity)
    summary = cached_summary(module) |> Map.merge(inferred) |> Map.put_new(key, :unknown)
    :ets.insert(@cache, {module, summary})
    Map.fetch!(summary, key)
  end

  defp cached_summary(module) do
    case :ets.lookup(@cache, module) do
      [{^module, summary}] -> summary
      [] -> %{}
    end
  end

  defp build(module, function, arity) do
    Process.put(@inference_key, module)

    case Frontend.BEAM.from_module(module,
           functions: [{function, arity}],
           max_functions: @max_dependency_functions
         ) do
      {:ok, nodes} -> build_summary(module, nodes)
      {:error, _reason} -> %{}
    end
  after
    Process.delete(@inference_key)
  end

  defp build_summary(module, nodes) do
    function_defs = Enum.filter(nodes, &(&1.type == :function_def))
    node_map = nodes |> IR.all_nodes() |> Map.new(&{&1.id, &1})
    :ok = Effects.infer_local_effects(node_map, @inference_plugins)
    Map.new(function_defs, &function_effect(module, &1))
  end

  defp function_effect(module, function_def) do
    call = %Node{
      id: 0,
      type: :call,
      meta: %{
        module: module,
        function: function_def.meta[:name],
        arity: function_def.meta[:arity],
        kind: :remote
      }
    }

    key = {module, function_def.meta[:name], function_def.meta[:arity]}
    {key, Effects.classify(call, @inference_plugins)}
  end

  defp ensure_cache do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
