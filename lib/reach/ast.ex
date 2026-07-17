defmodule Reach.AST do
  @moduledoc "Shared helpers for working with Elixir AST."

  @doc "Returns real `defmodule` AST nodes from a quoted source tree."
  def modules_in_file(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_name, body]} = module, modules when is_list(body) ->
          {module, [module | modules]}

        node, modules ->
          {node, modules}
      end)

    Enum.reverse(modules)
  end

  @doc "Returns a static module name represented by alias AST."
  @spec module_name(Macro.t()) :: {:ok, module()} | :error
  def module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  def module_name(_ast), do: :error

  @doc "Returns the name and arity represented by a function head."
  @spec function_identity(Macro.t()) :: {:ok, atom(), non_neg_integer()} | :error
  def function_identity({:when, _meta, [head | _guards]}), do: function_identity(head)
  def function_identity({name, _meta, nil}) when is_atom(name), do: {:ok, name, 0}

  def function_identity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, length(args)}

  def function_identity(_head), do: :error

  @doc "Returns the module, function, and arguments represented by an Elixir call AST node."
  @spec call(Macro.t()) :: {module() | nil, atom(), [Macro.t()]} | nil
  def call({{:., _dot_meta, [module_ast, name]}, _meta, args})
      when is_atom(name) and is_list(args) do
    case ast_module(module_ast) do
      nil -> nil
      module -> {module, name, args}
    end
  end

  def call({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {nil, name, args}

  def call(_ast), do: nil

  @doc "Returns whether keyword AST contains a key."
  @spec keyword?(Macro.t(), atom()) :: boolean()
  def keyword?(entries, key) when is_list(entries) do
    Enum.any?(entries, fn
      {{:__block__, _meta, [^key]}, _value} -> true
      {^key, _value} -> true
      _entry -> false
    end)
  end

  def keyword?(_entries, _key), do: false

  @doc "Fetches a value from ordinary or Sourceror-wrapped keyword AST."
  @spec keyword_fetch(Macro.t(), atom()) :: {:ok, Macro.t()} | :error
  def keyword_fetch(entries, key) when is_list(entries) do
    Enum.find_value(entries, :error, fn
      {{:__block__, _meta, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _entry -> false
    end)
  end

  def keyword_fetch(_entries, _key), do: :error

  @doc "Returns a value from ordinary or Sourceror-wrapped keyword AST."
  @spec keyword_value(Macro.t(), atom()) :: Macro.t() | nil
  def keyword_value(entries, key) do
    case keyword_fetch(entries, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp ast_module({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Module.safe_concat(parts)
    end
  rescue
    ArgumentError -> nil
  end

  defp ast_module(module) when is_atom(module), do: module
  defp ast_module(_ast), do: nil
end
