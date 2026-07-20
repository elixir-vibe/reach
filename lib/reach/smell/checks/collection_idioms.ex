defmodule Reach.Smell.Checks.CollectionIdioms do
  @moduledoc "Pattern-based detection of suboptimal collection operations."

  use Reach.Smell.Check.Source

  alias Reach.Smell.Helpers

  smell(
    ~p[Enum.reverse(_) ++ _],
    :suboptimal,
    "Enum.reverse(list) ++ tail traverses twice; use Enum.reverse(list, tail)",
    remediation_safety: :equivalent
  )

  smell(
    ~p[String.graphemes(_) |> length()],
    :suboptimal,
    "String.graphemes/1 |> length/1 builds an intermediate list; use String.length/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[String.graphemes(_) |> Enum.count()],
    :suboptimal,
    "String.graphemes/1 |> Enum.count/1 builds an intermediate list; use String.length/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[String.length(_) == 1],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one grapheme; review String.next_grapheme/1 when this is hot (byte-pattern matching is not Unicode-equivalent)"
  )

  smell(
    ~p[1 == String.length(_)],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one grapheme; review String.next_grapheme/1 when this is hot (byte-pattern matching is not Unicode-equivalent)"
  )

  smell(
    ~p[String.length(_) != 1],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one grapheme; review String.next_grapheme/1 when this is hot (byte-pattern matching is not Unicode-equivalent)"
  )

  smell(
    ~p[1 != String.length(_)],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one grapheme; review String.next_grapheme/1 when this is hot (byte-pattern matching is not Unicode-equivalent)"
  )

  smell(
    ~p[inspect(_) |> String.starts_with?(_)],
    :suboptimal,
    "inspect/1 for module/atom membership is fragile; review Module.split/1 or direct atom comparison after preserving accepted input types"
  )

  smell(
    ~p[inspect(_) |> String.contains?(_)],
    :suboptimal,
    "inspect/1 for type checking is fragile; review direct atom comparison or Module.split/1 after preserving accepted input types"
  )

  smell(
    ~p[Map.keys(_) |> Enum.each(_)],
    :suboptimal,
    "Map.keys/1 → Enum.each: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.flat_map(_)],
    :suboptimal,
    "Map.keys/1 → Enum.flat_map: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.join()],
    :suboptimal,
    "Map.keys/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.join(_)],
    :suboptimal,
    "Map.keys/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.uniq()],
    :suboptimal,
    "Map.keys/1 returns unique keys already; Enum.uniq/1 is redundant",
    remediation_safety: :equivalent
  )

  smell(
    ~p[String.graphemes(_) |> Enum.reverse() |> Enum.join()],
    :suboptimal,
    "String.graphemes |> Enum.reverse |> Enum.join; use String.reverse/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.values(_) |> Enum.all?(_)],
    :suboptimal,
    "Map.values/1 → Enum.all?: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.any?(_)],
    :suboptimal,
    "Map.values/1 → Enum.any?: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.find(_)],
    :suboptimal,
    "Map.values/1 → Enum.find: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.join()],
    :suboptimal,
    "Map.values/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.join(_)],
    :suboptimal,
    "Map.values/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.sum()],
    :suboptimal,
    "Map.values/1 → Enum.sum: iterate the map directly with Enum.reduce/3"
  )

  smell(
    ~p[Map.values(_) |> Enum.max()],
    :suboptimal,
    "Map.values/1 → Enum.max/1 allocates a values list; review a direct reduce if allocation matters (Enum.max_by/2 on the map returns a {key, value} pair)"
  )

  smell(
    ~p[Map.values(_) |> Enum.min()],
    :suboptimal,
    "Map.values/1 → Enum.min/1 allocates a values list; review a direct reduce if allocation matters (Enum.min_by/2 on the map returns a {key, value} pair)"
  )

  # length(list) == 0 → list == []
  smell(
    ~p[length(_) == 0],
    :suboptimal,
    "length/1 == 0 is O(n); review a list pattern or == [] only when malformed-list exception parity is not required"
  )

  smell(
    ~p[0 == length(_)],
    :suboptimal,
    "length/1 == 0 is O(n); review a list pattern or == [] only when malformed-list exception parity is not required"
  )

  # length(list) > 0 → list != [] or match?([_|_], list)
  smell(
    ~p[length(_) > 0],
    :suboptimal,
    "length/1 > 0 is O(n); review a non-empty-list pattern only when malformed-list exception parity is not required"
  )

  smell(
    from(~p[Regex.replace(_, _, _)]) |> where(piped()),
    :suboptimal,
    "Regex.replace/3 receives the piped value as its regex argument; verify argument order and retain Regex.replace when regex semantics are intended"
  )

  smell(
    from(~p[Regex.replace(_, _, _, _)]) |> where(piped()),
    :suboptimal,
    "Regex.replace/4 receives the piped value as its regex argument; verify argument order and retain Regex.replace when regex semantics are intended"
  )

  smell(
    ~p[Map.keys(_) |> Enum.member?(_)],
    :suboptimal,
    "Map.keys/1 → Enum.member?: use Map.has_key?/2 directly",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.values(_) |> Enum.count()],
    :suboptimal,
    "Map.values/1 → Enum.count: use map_size/1 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.keys(_) |> Enum.count()],
    :suboptimal,
    "Map.keys/1 → Enum.count: use map_size/1 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.keys(_) |> length()],
    :suboptimal,
    "Map.keys/1 → length: use map_size/1 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.values(_) |> length()],
    :suboptimal,
    "Map.values/1 → length: use map_size/1 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[if left >= right, do: left, else: right],
    :suboptimal,
    "if a >= b, do: a, else: b reimplements max/2; use Kernel.max/2",
    remediation_safety: :equivalent
  )

  smell(
    ~p[if left <= right, do: left, else: right],
    :suboptimal,
    "if a <= b, do: a, else: b reimplements min/2; use Kernel.min/2",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.into(%{})],
    :suboptimal,
    "Enum.map/2 |> Enum.into(%{}) allocates an intermediate list; use Map.new/2 only when the mapper is pure and always returns a {key, value} pair, because fusion changes failure timing",
    remediation_safety: :conditional
  )

  smell(
    ~p[Enum.into(_, MapSet.new())],
    :suboptimal,
    "Enum.into(enum, MapSet.new()): use MapSet.new/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.into(_, MapSet.new(), _)],
    :suboptimal,
    "Enum.into(enum, MapSet.new(), mapper): use MapSet.new/2",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.new(Enum.to_list(_))],
    :suboptimal,
    "Enum.to_list/1 before Map.new/1 is redundant when every yielded item is a {key, value} pair; direct construction changes invalid-item failure timing",
    remediation_safety: :conditional
  )

  smell(
    ~p[MapSet.new(Enum.to_list(_))],
    :suboptimal,
    "Enum.to_list/1 before MapSet.new/1 is redundant; MapSet.new/1 accepts any enumerable",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.dedup(_) |> MapSet.new()],
    :redundant_traversal,
    "Enum.dedup/1 before MapSet.new/1 is redundant; MapSet stores unique elements already",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.uniq(_) |> MapSet.new()],
    :redundant_traversal,
    "Enum.uniq/1 before MapSet.new/1 is redundant; MapSet stores unique elements already",
    remediation_safety: :equivalent
  )

  smell(
    from(~p[Enum.map(Enum.chunk_by(_, callback), first_fn)])
    |> where(Helpers.identity_fn?(^callback) and first_element_fn?(^first_fn)),
    :suboptimal,
    "Enum.chunk_by/2 with identity followed by first-element mapping reimplements Enum.dedup/1"
  )

  smell(
    from(~p[Enum.map_join(Enum.chunk_by(_, callback), first_fn)])
    |> where(Helpers.identity_fn?(^callback) and first_element_fn?(^first_fn)),
    :suboptimal,
    "Enum.chunk_by/2 with identity followed by map_join reimplements Enum.dedup/1 |> Enum.join/1"
  )

  smell(
    from(~p[Map.new(Enum.group_by(_, _), callback)])
    |> where(length_of_group_fn?(^callback)),
    :suboptimal,
    "Enum.group_by/2 followed by Map.new/2 counting group lengths is a manual frequency count; use Enum.frequencies_by/2",
    remediation_safety: :equivalent
  )

  smell(
    from(~p[Map.new(_, fn param -> body end)])
    |> where(bare_param?(^param) and definitely_not_pair?(^body)),
    :bug_risk,
    "Map.new/2 mapper must return a {key, value} tuple; this bare literal raises ArgumentError"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.concat()],
    :eager_pattern,
    "Enum.map/2 |> Enum.concat/1 allocates an intermediate list; fuse with Enum.flat_map/2 only when callbacks are pure and every mapped result is a proper list, because fusion changes failure timing",
    remediation_safety: :conditional
  )

  smell(
    from(~p[Enum.join(List.duplicate(value, _))])
    |> where(string_literal?(^value)),
    :suboptimal,
    "List.duplicate/2 followed by Enum.join/1 repeats a string through an intermediate list; use String.duplicate/2",
    remediation_safety: :equivalent
  )

  smell(
    from(~p[Enum.into(_, target)])
    |> where(match?({:%{}, _, []}, ^target)),
    :suboptimal,
    "Enum.into(enum, %{}): use Map.new/1",
    remediation_safety: :equivalent
  )

  defp bare_param?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp bare_param?(_value), do: false

  defp definitely_not_pair?({:__block__, _meta, [inner]}), do: definitely_not_pair?(inner)
  defp definitely_not_pair?(list) when is_list(list), do: true

  defp definitely_not_pair?(literal)
       when is_integer(literal) or is_float(literal) or is_atom(literal) or is_binary(literal),
       do: true

  defp definitely_not_pair?({:%{}, _meta, _fields}), do: true
  defp definitely_not_pair?({:<<>>, _meta, _parts}), do: true
  defp definitely_not_pair?({:{}, _meta, [_left, _right]}), do: false
  defp definitely_not_pair?({:{}, _meta, elements}) when is_list(elements), do: true
  defp definitely_not_pair?(_value), do: false

  defp string_literal?({:__block__, _meta, [value]}) when is_binary(value), do: true
  defp string_literal?(value) when is_binary(value), do: true
  defp string_literal?(_value), do: false

  smell(
    ~p[Keyword.get(_, _, nil)],
    :suboptimal,
    "Keyword.get/3 with nil default is redundant; nil is already the default for Keyword.get/2",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Map.get(_, _, nil)],
    :suboptimal,
    "Map.get/3 with nil default is redundant; nil is already the default for Map.get/2",
    remediation_safety: :equivalent
  )

  smell(
    ~p[String.split(_, _) |> hd()],
    :suboptimal,
    "String.split/2 |> hd/1 splits the entire string; use String.split/3 with parts: 2"
  )

  smell(
    ~p[String.split(_, _) |> List.first()],
    :suboptimal,
    "String.split/2 |> List.first/1 splits the entire string; use String.split/3 with parts: 2"
  )

  smell(
    ~p[Enum.take_while(_, _) |> length()],
    :suboptimal,
    "Enum.take_while/2 |> length/1 materializes a prefix just to count it; use Enum.reduce_while/3"
  )

  smell(
    ~p[Enum.take_while(_, _) |> Enum.count()],
    :suboptimal,
    "Enum.take_while/2 |> Enum.count/1 materializes a prefix just to count it; use Enum.reduce_while/3"
  )

  defp first_element_fn?(
         {:&, _,
          [
            {:/, _,
             [
               {{:., _, [{:__aliases__, _, [:List]}, :first]}, _, []},
               arity
             ]}
          ]}
       ),
       do: unwrap_literal(arity) == 1

  defp first_element_fn?({:&, _, [{:hd, _, [{:&, _, [1]}]}]}), do: true
  defp first_element_fn?(_callback), do: false

  defp length_of_group_fn?(
         {:fn, _,
          [
            {:->, _,
             [
               [pattern],
               result
             ]}
          ]}
       ) do
    with {:ok, key_var, group_var} <- group_tuple(pattern),
         {:ok, result_key, length_call} <- result_tuple(result) do
      same_var?(key_var, result_key) and length_call_on?(length_call, group_var)
    else
      _ -> false
    end
  end

  defp length_of_group_fn?(_callback), do: false

  defp group_tuple({:__block__, _meta, [inner]}), do: group_tuple(inner)
  defp group_tuple({key_var, group_var}), do: {:ok, key_var, group_var}
  defp group_tuple({:{}, _meta, [key_var, group_var]}), do: {:ok, key_var, group_var}
  defp group_tuple(_other), do: :error

  defp result_tuple({:__block__, _meta, [inner]}), do: result_tuple(inner)
  defp result_tuple({key_var, length_call}), do: {:ok, key_var, length_call}
  defp result_tuple({:{}, _meta, [key_var, length_call]}), do: {:ok, key_var, length_call}
  defp result_tuple(_other), do: :error

  defp length_call_on?({:length, _, [var]}, group_var), do: same_var?(var, group_var)

  defp length_call_on?({{:., _, [{:__aliases__, _, [:Kernel]}, :length]}, _, [var]}, group_var),
    do: same_var?(var, group_var)

  defp length_call_on?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [var]}, group_var),
    do: same_var?(var, group_var)

  defp length_call_on?(_call, _group_var), do: false

  defp same_var?({name, _, ctx}, {name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp same_var?(_left, _right), do: false

  defp unwrap_literal({:__block__, _meta, [value]}), do: value
  defp unwrap_literal(value), do: value
end
