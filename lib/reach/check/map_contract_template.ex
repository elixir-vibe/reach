defmodule Reach.Check.MapContractTemplate do
  @moduledoc "Builds source-backed fix templates for implicit map-contract candidates."

  alias Reach.Evidence.Impact
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  @field_name ~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/

  @spec build(
          [map()],
          [term()],
          atom(),
          Reach.Project.t(),
          map()
        ) ::
          map()
  def build(contracts, keys, kind, project, candidate_config) do
    functions = contract_functions(contracts, project)
    canonical_site = canonical_site(contracts, project)

    %{
      canonical_site: canonical_site,
      draft_contract: draft_contract(keys, kind),
      blast_radius: blast_radius(functions, project, candidate_config)
    }
  end

  defp canonical_site(contracts, project) do
    contracts
    |> Enum.flat_map(&construction_sites(&1, project))
    |> Enum.group_by(&{&1.target, &1.file, &1.line, &1.reason})
    |> Enum.map(fn {_identity, sites} -> {List.first(sites), length(sites)} end)
    |> Enum.min_by(
      fn {site, occurrences} ->
        {site_reason_rank(site.reason), -occurrences, site.file || "", site.line || 0,
         site.target}
      end,
      fn -> nil end
    )
    |> case do
      {site, _occurrences} -> site
      nil -> nil
    end
  end

  defp construction_sites(contract, project) do
    producer_sites(contract, project) ++ local_construction_sites(contract, project)
  end

  defp producer_sites(%{producer: producer} = contract, project) when not is_nil(producer) do
    case resolve_producer(producer, contract, project) do
      nil -> []
      target -> [site(target, project, :existing_producer)]
    end
  end

  defp producer_sites(_contract, _project), do: []

  defp local_construction_sites(%{source: :local} = contract, project) do
    case contract_function(contract, project) do
      nil -> []
      target -> [site(target, contract.file, contract.location.line, :map_literal)]
    end
  end

  defp local_construction_sites(_contract, _project), do: []

  defp resolve_producer({module, function, arity}, _contract, project)
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    target = {module, function, arity}
    if Query.find_function(project, target), do: target
  end

  defp resolve_producer({function, arity}, contract, project)
       when is_atom(function) and is_integer(arity) do
    case contract_function(contract, project) do
      {module, _consumer, _consumer_arity} ->
        target = {module, function, arity}
        if Query.find_function(project, target), do: target

      nil ->
        nil
    end
  end

  defp resolve_producer(_producer, _contract, _project), do: nil

  defp contract_functions(contracts, project) do
    contracts
    |> Enum.flat_map(fn contract ->
      producer =
        case contract.producer do
          nil -> nil
          value -> resolve_producer(value, contract, project)
        end

      [producer, contract_function(contract, project)]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp contract_function(%{consumer: {module, function, arity}}, _project)
       when is_atom(module) and is_atom(function) and is_integer(arity),
       do: {module, function, arity}

  defp contract_function(%{file: file, location: %{line: line}}, project)
       when is_binary(file) and is_integer(line) do
    case Query.find_function_at_location(project, file, line) do
      nil -> nil
      function -> {function.meta[:module], function.meta[:name], function.meta[:arity]}
    end
  end

  defp contract_function(_contract, _project), do: nil

  defp site(target, project, reason) do
    function = Query.find_function(project, target)
    site(target, function.source_span.file, function.source_span.start_line, reason)
  end

  defp site(target, file, line, reason) do
    %{target: IRHelpers.func_id_to_string(target), file: file, line: line, reason: reason}
  end

  defp site_reason_rank(:existing_producer), do: 0
  defp site_reason_rank(:map_literal), do: 1

  defp draft_contract(keys, :introduce_typed_map_contract) do
    fields = Enum.map_join(keys, ",\n  ", &"required(#{key_literal(&1)}) => term()")
    "@type t :: %{\n  #{fields}\n}"
  end

  defp draft_contract(keys, _kind) do
    if Enum.all?(keys, &field_name?/1) do
      fields = Enum.map_join(keys, ", ", &":#{&1}")
      "@enforce_keys [#{fields}]\ndefstruct [#{fields}]"
    else
      "validation schema with required keys #{inspect(keys)}"
    end
  end

  defp field_name?(key), do: Regex.match?(@field_name, to_string(key))

  defp key_literal(key) when is_atom(key), do: inspect(key)
  defp key_literal(key) when is_binary(key), do: inspect(key)
  defp key_literal(key), do: inspect(key)

  defp blast_radius(functions, project, candidate_config) do
    functions
    |> Enum.flat_map(fn target ->
      [
        target
        | Impact.callers(project, target, candidate_config.limits.boundary_contract_impact_depth)
      ]
    end)
    |> Enum.uniq()
    |> Enum.take(candidate_config.limits.boundary_contract_blast_radius)
    |> Enum.map(&IRHelpers.func_id_to_string/1)
  end
end
