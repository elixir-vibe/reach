defmodule Reach.Smell.PatternConfig do
  @moduledoc false

  def normalize(module, %{patterns: patterns, queries: queries} = config) do
    %{
      config
      | patterns: Enum.map(patterns, &normalize_pattern/1),
        queries: Enum.map(queries, &normalize_query(module, &1))
    }
  end

  def normalize_pattern({pattern, kind, message}),
    do: normalize_pattern({pattern, kind, message, :auto, :review_only})

  def normalize_pattern({pattern, kind, message, prefilter}),
    do: normalize_pattern({pattern, kind, message, prefilter, :review_only})

  def normalize_pattern({pattern, kind, message, prefilter, remediation_safety}) do
    normalized_prefilter = inferred_prefilter(pattern, prefilter)
    {ExAST.Pattern.compile(pattern), kind, message, normalized_prefilter, remediation_safety}
  end

  def normalize_query(module, {fun_name, kind, message}),
    do: normalize_query(module, {fun_name, kind, message, :auto, :review_only})

  def normalize_query(module, {fun_name, kind, message, prefilter}),
    do: normalize_query(module, {fun_name, kind, message, prefilter, :review_only})

  def normalize_query(module, {fun_name, kind, message, prefilter, remediation_safety}) do
    selector = apply(module, fun_name, [])
    {fun_name, kind, message, inferred_prefilter(selector, prefilter), remediation_safety}
  end

  def prefiltered?({_name_or_pattern, _kind, _message, prefilter, _remediation_safety}),
    do: prefilter != []

  def source_matches?(_source, []), do: true
  def source_matches?(nil, _prefilter), do: true

  def source_matches?(source, {:all, prefilter}) when is_list(prefilter) do
    Enum.all?(prefilter, &String.contains?(source, &1))
  end

  def source_matches?(source, prefilter) when is_list(prefilter) do
    Enum.any?(prefilter, &String.contains?(source, &1))
  end

  def source_matches?(source, prefilter) when is_binary(prefilter),
    do: String.contains?(source, prefilter)

  defp inferred_prefilter(_term, false), do: []
  defp inferred_prefilter(_term, nil), do: []
  defp inferred_prefilter(_term, prefilter) when is_binary(prefilter), do: [prefilter]
  defp inferred_prefilter(_term, prefilter) when is_list(prefilter), do: prefilter

  defp inferred_prefilter(term, :auto) do
    case term |> remote_call_tokens() |> Enum.uniq() do
      [] -> fallback_prefilter(term)
      tokens -> tokens
    end
  end

  defp fallback_prefilter(term) do
    case structural_prefilter(term) do
      [] -> term |> local_call_tokens() |> Enum.uniq()
      prefilter -> prefilter
    end
  end

  defp structural_prefilter(term) do
    case term |> structural_tokens() |> Enum.uniq() do
      [] -> []
      tokens -> {:all, tokens}
    end
  end

  defp remote_call_tokens(term), do: remote_call_tokens(term, [])

  defp remote_call_tokens({{:., _, [{:__aliases__, _, aliases}, function]}, _, args}, tokens)
       when is_atom(function) do
    token = Enum.map_join(aliases, ".", &Atom.to_string/1) <> "." <> Atom.to_string(function)
    Enum.reduce(args, [token | tokens], &remote_call_tokens/2)
  end

  defp remote_call_tokens({:__aliases__, _, _aliases}, tokens), do: tokens

  defp remote_call_tokens(tuple, tokens) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(tokens, &remote_call_tokens/2)
  end

  defp remote_call_tokens(list, tokens) when is_list(list),
    do: Enum.reduce(list, tokens, &remote_call_tokens/2)

  defp remote_call_tokens(map, tokens) when is_map(map) do
    map
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(tokens, &remote_call_tokens/2)
  end

  defp remote_call_tokens(_term, tokens), do: tokens

  defp local_call_tokens(term), do: local_call_tokens(term, [])

  defp local_call_tokens(%ExAST.Selector{steps: steps}, tokens),
    do: local_call_tokens(steps, tokens)

  defp local_call_tokens(%ExAST.Selector.Predicate{}, tokens), do: tokens

  defp local_call_tokens({name, _meta, args}, tokens) when is_atom(name) and is_list(args) do
    args
    |> Enum.reduce(tokens, &local_call_tokens/2)
    |> then(&[Atom.to_string(name) | &1])
  end

  defp local_call_tokens(tuple, tokens) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(tokens, &local_call_tokens/2)
  end

  defp local_call_tokens(list, tokens) when is_list(list),
    do: Enum.reduce(list, tokens, &local_call_tokens/2)

  defp local_call_tokens(map, tokens) when is_map(map), do: tokens
  defp local_call_tokens(_term, tokens), do: tokens

  defp structural_tokens(term), do: structural_tokens(term, [])

  defp structural_tokens(%ExAST.Selector{steps: steps}, tokens),
    do: structural_tokens(steps, tokens)

  defp structural_tokens(%ExAST.Selector.Predicate{}, tokens), do: tokens

  defp structural_tokens({name, _meta, args}, tokens) when is_atom(name) and is_list(args) do
    args
    |> Enum.reduce(tokens, &structural_tokens/2)
    |> structural_token(name)
  end

  defp structural_tokens(tuple, tokens) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(tokens, &structural_tokens/2)
  end

  defp structural_tokens(list, tokens) when is_list(list),
    do: Enum.reduce(list, tokens, &structural_tokens/2)

  defp structural_tokens(map, tokens) when is_map(map), do: tokens

  defp structural_tokens(atom, tokens) when is_atom(atom), do: structural_token(tokens, atom)
  defp structural_tokens(_term, tokens), do: tokens

  defp structural_token(tokens, name) when name in [:case, :cond, :if, :unless, :fn, :defp],
    do: [Atom.to_string(name) | tokens]

  defp structural_token(tokens, value) when value in [true, false],
    do: [Atom.to_string(value) | tokens]

  defp structural_token(tokens, _name), do: tokens
end
