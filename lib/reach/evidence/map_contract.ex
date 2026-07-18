defmodule Reach.Evidence.MapContract do
  @moduledoc "Collects evidence for maps that behave like implicit contracts."
  @behaviour Reach.Evidence.Provider

  alias Reach.Evidence.AST
  alias Reach.Project.Query

  defmodule KeyAccess do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :node,
      :function,
      :map_origins,
      :key_origins,
      :logical_key,
      :key_label,
      :representation,
      :operation,
      :default_node,
      :location
    ]
  end

  defmodule Fallback do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :node,
      :function,
      :accesses,
      :location,
      :operator,
      :boolean_evidence,
      default?: false,
      returned?: false
    ]
  end

  defmodule KeyNormalization do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:node, :map_node, :function, :direction, :source_key, :location]
  end

  defmodule RepresentationChurn do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:node, :function, :first, :second, :location]
  end

  defmodule Contract do
    @moduledoc false
    @type t :: %__MODULE__{
            variable: String.t() | nil,
            keys: [String.t()],
            location: String.t() | nil,
            reads: [term()],
            updates: [term()],
            confidence: atom() | nil,
            source: term(),
            producer: term(),
            role: atom() | nil,
            key_coverage: float() | nil,
            observed_keys: [String.t()],
            unused_keys: [String.t()],
            read_count: non_neg_integer(),
            mutation_count: non_neg_integer(),
            escaped?: boolean(),
            escapes: [term()],
            consumer: term(),
            file: String.t() | nil,
            representations: map(),
            accesses: [KeyAccess.t()],
            parameter: term()
          }

    defstruct [
      :variable,
      :keys,
      :location,
      :reads,
      :updates,
      :confidence,
      :source,
      :producer,
      :role,
      :key_coverage,
      :observed_keys,
      :unused_keys,
      :read_count,
      :mutation_count,
      :escaped?,
      :escapes,
      :consumer,
      :file,
      :representations,
      :accesses,
      :parameter
    ]
  end

  @min_keys 3
  @min_observations 2
  @assigns_names [:assigns]
  @accumulator_names [:acc, :cat, :count, :counts, :stats]
  @external_payload_names [:body, :json, :metadata, :payload, :request, :response]
  @options_names [:config, :opts, :options]
  @boolean_key_terms ~w(active allow allowed disabled enabled flag hidden valid visible)
  @non_call_forms [:., :%, :{}, :__aliases__, :__block__, :=, :->, :def, :defp, :fn, :|>]

  @impl true
  def family, do: :map_contract

  @impl true
  def kinds, do: [:implicit_map_contract]

  def collect_key_accesses(%{nodes: nodes, call_graph: _call_graph} = project)
      when is_map(nodes) do
    function_index = Query.function_index(project)
    predecessor_index = Query.value_predecessor_index(project)

    nodes
    |> Map.values()
    |> Enum.flat_map(&classify_key_access(&1, project, function_index, predecessor_index))
  end

  def collect_key_accesses(_project), do: []

  @doc "Indexes direct function-parameter bindings by their zero-based parameter position."
  @spec parameter_origin_index(map()) ::
          %{{{module() | nil, atom(), non_neg_integer()}, term()} => non_neg_integer()}
  def parameter_origin_index(%{nodes: nodes}) when is_map(nodes) do
    nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reduce(%{}, &index_function_parameters/2)
  end

  def parameter_origin_index(_project), do: %{}

  def collect_key_normalizations(%{nodes: nodes, call_graph: _call_graph} = project)
      when is_map(nodes) do
    parent_index = parent_index(nodes)
    function_index = Query.function_index(project)

    nodes
    |> Map.values()
    |> Enum.flat_map(&key_normalizations(&1, project, parent_index, function_index))
  end

  def collect_key_normalizations(_project), do: []

  def collect_representation_churn(project) do
    collect_representation_churn(project, collect_key_normalizations(project))
  end

  def collect_representation_churn(_project, []), do: []

  def collect_representation_churn(project, normalizations) do
    function_index = Query.function_index(project)

    normalizations
    |> normalization_calls(project, function_index)
    |> Enum.group_by(fn {call, _normalization} -> function_index.node_to_function[call.id] end)
    |> Enum.flat_map(fn {function, calls} -> representation_churn(calls, function, project) end)
  end

  def collect_fallbacks(project) do
    accesses_by_node = Map.new(collect_key_accesses(project), &{&1.node.id, &1})
    parent_index = parent_index(project.nodes)

    project.nodes
    |> Map.values()
    |> Enum.flat_map(&fallback_for_node(&1, accesses_by_node, parent_index))
    |> Enum.filter(&dual_representation_fallback?/1)
  end

  @impl true
  def collect_ast(ast, opts \\ []) do
    plugins = Keyword.get(opts, :plugins, [])
    context = Keyword.get(opts, :context, %{})

    ast
    |> collect_function_definitions()
    |> collect_ast_contracts()
    |> refine_contracts(plugins, context)
  end

  def collect_project(project, opts \\ []) do
    plugins = Keyword.get(opts, :plugins, project_plugins(project))

    files =
      project
      |> project_source_files()
      |> Enum.map(&source_file_ast/1)
      |> Enum.filter(&match?({:ok, _file, _ast}, &1))

    definitions_by_file =
      Map.new(files, fn {:ok, file, ast} -> {file, collect_module_definitions(ast)} end)

    return_shapes =
      definitions_by_file
      |> Map.values()
      |> List.flatten()
      |> collect_module_return_shapes()

    ast_contracts =
      Enum.flat_map(files, fn {:ok, file, ast} ->
        contracts =
          collect_file_project_contracts(
            file,
            ast,
            Map.fetch!(definitions_by_file, file),
            return_shapes
          )

        refine_contracts(contracts, plugins, %{file: file, project: project})
      end)

    ast_contracts ++ fallback_contracts(project)
  end

  defp collect_ast_contracts(definitions) do
    collect_local_contracts(definitions) ++ collect_return_contracts(definitions)
  end

  defp refine_contracts(contracts, [], _context), do: contracts

  defp refine_contracts(contracts, plugins, context) do
    Enum.map(contracts, &Reach.Plugin.refine_evidence(plugins, &1, context))
  end

  defp project_plugins(project) when is_map(project), do: Map.get(project, :plugins, [])
  defp project_plugins(_project), do: []

  defp project_source_files(project), do: Reach.Source.project_files(project)

  defp source_file_ast(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, file, ast}
    end
  end

  defp key_normalizations(
         %{type: :call, meta: %{module: Map, function: :new, arity: 2}, children: [map, mapper]},
         project,
         parent_index,
         function_index
       ) do
    mapper
    |> descendants()
    |> Enum.flat_map(fn node ->
      with {:ok, direction, source_key} <- key_conversion(node),
           {:ok, conditional} <- identity_branch(node, source_key, parent_index),
           true <- conversion_reaches_returned_key?(conditional, mapper, project) do
        [
          %KeyNormalization{
            node: node,
            map_node: map,
            function: Map.get(function_index.node_to_function, node.id),
            direction: direction,
            source_key: source_key,
            location: node_location(node)
          }
        ]
      else
        _other -> []
      end
    end)
  end

  defp key_normalizations(_node, _project, _parent_index, _function_index), do: []

  defp key_conversion(%{
         type: :call,
         meta: %{module: Atom, function: :to_string},
         children: [source]
       }) do
    with {:ok, name} <- ir_variable_name(source), do: {:ok, :atom_to_string, name}
  end

  defp key_conversion(%{
         type: :call,
         meta: %{module: String, function: function},
         children: [source]
       })
       when function in [:to_atom, :to_existing_atom] do
    with {:ok, name} <- ir_variable_name(source), do: {:ok, :string_to_atom, name}
  end

  defp key_conversion(_node), do: :error

  defp ir_variable_name(%{type: :var, meta: %{name: name}}), do: {:ok, name}
  defp ir_variable_name(_node), do: :error

  defp identity_branch(conversion, source_key, parent_index) do
    branch = ancestor_parent(conversion, parent_index, &(&1.type == :clause))

    case ancestor_parent(branch, parent_index, &(&1.type in [:case, :fn])) do
      %{type: :case} = conditional ->
        case_identity_branch(conditional, branch, source_key)

      %{type: :fn} = mapper ->
        mapper_identity_branch(mapper, branch, conversion, source_key)

      _other ->
        :error
    end
  end

  defp case_identity_branch(conditional, branch, source_key) do
    if Enum.any?(
         conditional.children,
         &(&1.type == :clause and &1.id != branch.id and returned_variable(&1) == source_key)
       ) do
      {:ok, conditional}
    else
      :error
    end
  end

  defp mapper_identity_branch(mapper, branch, conversion, source_key) do
    if Enum.any?(
         mapper.children,
         &(&1.type == :clause and &1.id != branch.id and
             returned_key_variable(&1) == source_key)
       ) do
      {:ok, conversion}
    else
      :error
    end
  end

  defp returned_variable(node) do
    node
    |> returned_child()
    |> ir_variable_name()
    |> case do
      {:ok, name} -> name
      :error -> nil
    end
  end

  defp returned_child(%{type: :block, children: children}),
    do: children |> List.last() |> returned_child()

  defp returned_child(%{type: :clause, children: children}),
    do: children |> List.last() |> returned_child()

  defp returned_child(node), do: node

  defp returned_key_variable(node) do
    case returned_child(node) do
      %{type: :tuple, children: [key_node, _value_node]} ->
        case ir_variable_name(key_node) do
          {:ok, name} -> name
          :error -> nil
        end

      _node ->
        nil
    end
  end

  defp conversion_reaches_returned_key?(conversion, mapper, project) do
    descendants = descendants(mapper)

    descendants
    |> Enum.filter(&(&1.type == :tuple and length(&1.children) == 2))
    |> Enum.any?(fn tuple ->
      [key_node, _value_node] = tuple.children

      not is_nil(Query.value_path(project, conversion, key_node)) or
        assigned_to_key?(conversion, key_node, descendants)
    end)
  end

  defp assigned_to_key?(conversion, key_node, descendants) do
    case ir_variable_name(key_node) do
      {:ok, key_name} ->
        Enum.any?(descendants, fn
          %{type: :match, children: [definition, value]} ->
            value.id == conversion.id and ir_variable_name(definition) == {:ok, key_name}

          _node ->
            false
        end)

      :error ->
        false
    end
  end

  defp descendants(node), do: [node | Enum.flat_map(node.children, &descendants/1)]

  defp index_function_parameters(function, index) do
    function_id = {function.meta[:module], function.meta[:name], function.meta[:arity]}

    function.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.reduce(index, fn clause, index ->
      clause.children
      |> Enum.take(function.meta[:arity])
      |> Stream.with_index()
      |> Enum.reduce(index, fn {parameter, parameter_index}, index ->
        parameter
        |> direct_parameter_origins()
        |> Enum.reduce(index, &Map.put(&2, {function_id, &1.id}, parameter_index))
      end)
    end)
  end

  defp direct_parameter_origins(parameter) do
    [parameter | direct_parameter_aliases(parameter)]
  end

  defp direct_parameter_aliases(%{type: :match, children: children}) do
    Enum.flat_map(children, fn
      %{type: :var} = variable -> [variable]
      %{type: :match} = match -> [match | direct_parameter_aliases(match)]
      _nested_pattern -> []
    end)
  end

  defp direct_parameter_aliases(_parameter), do: []

  defp ancestor_parent(nil, _parent_index, _predicate), do: nil

  defp ancestor_parent(node, parent_index, predicate) do
    parent_index
    |> Map.get(node.id, [])
    |> Enum.find_value(fn parent ->
      if predicate.(parent), do: parent, else: ancestor_parent(parent, parent_index, predicate)
    end)
  end

  defp normalization_calls(normalizations, project, function_index) do
    for node <- Map.values(project.nodes),
        node.type == :call,
        normalization <- normalizations,
        normalization_call?(node, normalization, function_index),
        do: {node, normalization}
  end

  defp normalization_call?(call, normalization, function_index) do
    case {normalization.function, call.meta} do
      {{module, name, arity}, %{module: call_module, function: name, arity: arity}} ->
        call_module == module or
          (is_nil(call_module) and
             match?(
               {^module, _caller_name, _caller_arity},
               function_index.node_to_function[call.id]
             ))

      _other ->
        false
    end
  end

  defp representation_churn(calls, function, project) do
    for {first_call, first_normalization} <- calls,
        {second_call, second_normalization} <- calls,
        first_call.id != second_call.id,
        first_normalization.direction != second_normalization.direction,
        second_input = List.first(second_call.children),
        not is_nil(second_input),
        not is_nil(Query.value_path(project, first_call, second_input)),
        uniq: true do
      %RepresentationChurn{
        node: second_call,
        function: function,
        first: first_normalization,
        second: second_normalization,
        location: node_location(second_call)
      }
    end
  end

  defp classify_key_access(
         %{type: :call, meta: %{module: Map, function: function, arity: arity}} = node,
         project,
         function_index,
         predecessor_index
       )
       when function in [:get, :fetch, :fetch!, :has_key?] and arity in [2, 3] do
    classify_key_access_node(node, project, function_index, predecessor_index, function)
  end

  defp classify_key_access(
         %{type: :call, meta: %{module: Access, function: :get, arity: arity}} = node,
         project,
         function_index,
         predecessor_index
       )
       when arity in [2, 3] do
    classify_key_access_node(node, project, function_index, predecessor_index, :get)
  end

  defp classify_key_access(_node, _project, _function_index, _predecessor_index), do: []

  defp classify_key_access_node(
         node,
         project,
         function_index,
         predecessor_index,
         function
       ) do
    case node.children do
      [map_node, key_node | rest] ->
        {logical_key, key_label, representation, key_origins} =
          classify_key_expression(key_node, project, predecessor_index)

        [
          %KeyAccess{
            node: node,
            function: Map.get(function_index.node_to_function, node.id),
            map_origins: origin_ids(project, map_node, predecessor_index),
            key_origins: key_origins,
            logical_key: logical_key,
            key_label: key_label,
            representation: representation,
            operation: function,
            default_node: List.first(rest),
            location: node_location(node)
          }
        ]

      _children ->
        []
    end
  end

  defp classify_key_expression(
         %{type: :literal, meta: %{value: key}} = node,
         _project,
         _predecessor_index
       )
       when is_atom(key) do
    {{:literal, Atom.to_string(key)}, Atom.to_string(key), :atom, [node.id]}
  end

  defp classify_key_expression(
         %{type: :literal, meta: %{value: key}} = node,
         _project,
         _predecessor_index
       )
       when is_binary(key) do
    {{:literal, key}, key, :string, [node.id]}
  end

  defp classify_key_expression(
         %{type: :call, meta: %{module: Atom, function: :to_string}, children: [source]},
         project,
         predecessor_index
       ) do
    origins = origin_ids(project, source, predecessor_index)
    {{:flow, origins}, dynamic_key_label(project, origins), :derived_string, origins}
  end

  defp classify_key_expression(
         %{
           type: :call,
           meta: %{module: String, function: function},
           children: [source]
         },
         project,
         predecessor_index
       )
       when function in [:to_existing_atom, :to_atom] do
    origins = origin_ids(project, source, predecessor_index)
    {{:flow, origins}, dynamic_key_label(project, origins), :derived_atom, origins}
  end

  defp classify_key_expression(node, project, predecessor_index) do
    origins = origin_ids(project, node, predecessor_index)
    {{:flow, origins}, dynamic_key_label(project, origins), :native, origins}
  end

  defp origin_ids(project, node, predecessor_index) do
    project
    |> Query.value_origins(node, predecessor_index: predecessor_index)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp dynamic_key_label(project, origins) do
    names =
      Enum.flat_map(origins, fn origin ->
        case Map.get(project.nodes, origin) do
          %{type: :var, meta: %{name: name}} -> [to_string(name)]
          _node -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    case names do
      [] -> "dynamic-key"
      names -> Enum.join(names, "|")
    end
  end

  defp parent_index(nodes) do
    Enum.reduce(nodes, %{}, fn {_id, node}, index ->
      Enum.reduce(node.children, index, fn child, index ->
        Map.update(index, child.id, [node], &[node | &1])
      end)
    end)
  end

  defp fallback_for_node(
         %{type: :binary_op, meta: %{operator: :||}} = node,
         accesses_by_node,
         parent_index
       ) do
    if nested_or?(node, parent_index) do
      []
    else
      operands = flatten_or_operands(node)
      accesses = Enum.flat_map(operands, &List.wrap(Map.get(accesses_by_node, &1.id)))
      default? = Enum.any?(operands, &(not Map.has_key?(accesses_by_node, &1.id)))

      fallback_groups(
        node,
        accesses,
        :or,
        default?,
        returned_expression?(node, parent_index),
        boolean_evidence(accesses, operands)
      )
    end
  end

  defp fallback_for_node(
         %{type: :call, meta: %{module: Map, function: :get, arity: 3}, children: children} =
           node,
         accesses_by_node,
         parent_index
       ) do
    case children do
      [_map, _key, %{type: :call} = nested] ->
        accesses =
          [Map.get(accesses_by_node, node.id), Map.get(accesses_by_node, nested.id)]
          |> Enum.reject(&is_nil/1)

        fallback_groups(
          node,
          accesses,
          :default,
          false,
          returned_expression?(node, parent_index),
          []
        )

      _children ->
        []
    end
  end

  defp fallback_for_node(_node, _accesses_by_node, _parent_index), do: []

  defp nested_or?(node, parent_index) do
    parent_index
    |> Map.get(node.id, [])
    |> Enum.any?(&match?(%{type: :binary_op, meta: %{operator: :||}}, &1))
  end

  defp returned_expression?(node, parent_index) do
    parent_index
    |> Map.get(node.id, [])
    |> Enum.any?(fn parent ->
      cond do
        parent.type == :function_def ->
          true

        parent.type in [:block, :clause, :case, :cond, :with] and
            List.last(parent.children).id == node.id ->
          returned_expression?(parent, parent_index)

        true ->
          false
      end
    end)
  end

  defp flatten_or_operands(%{type: :binary_op, meta: %{operator: :||}, children: children}) do
    Enum.flat_map(children, &flatten_or_operands/1)
  end

  defp flatten_or_operands(node), do: [node]

  defp boolean_evidence(accesses, operands) do
    access_ids = MapSet.new(accesses, & &1.node.id)

    key_evidence =
      accesses
      |> Enum.filter(&boolean_key_label?(&1.key_label))
      |> Enum.map(&{:boolean_key, &1.key_label})

    function_evidence =
      accesses
      |> Enum.map(& &1.function)
      |> Enum.uniq()
      |> Enum.filter(&predicate_function?/1)
      |> Enum.map(&{:predicate_function, &1})

    default_evidence =
      operands
      |> Enum.reject(&MapSet.member?(access_ids, &1.id))
      |> Enum.flat_map(fn
        %{type: :literal, meta: %{value: value}} = node when is_boolean(value) ->
          [{:boolean_default, value, node_location(node)}]

        _node ->
          []
      end)

    Enum.uniq(key_evidence ++ function_evidence ++ default_evidence)
  end

  defp boolean_key_label?(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.split(["_", "-", "?"], trim: true)
    |> Enum.any?(&(&1 in @boolean_key_terms))
  end

  defp boolean_key_label?(_label), do: false

  defp predicate_function?({_module, name, _arity}) when is_atom(name),
    do: name |> Atom.to_string() |> String.ends_with?("?")

  defp predicate_function?(_function), do: false

  defp fallback_groups(node, accesses, operator, default?, returned?, boolean_evidence) do
    accesses
    |> Enum.group_by(&{&1.function, &1.map_origins, &1.logical_key})
    |> Enum.map(fn {_identity, grouped_accesses} ->
      %Fallback{
        node: node,
        function: List.first(grouped_accesses).function,
        accesses: grouped_accesses,
        location: node_location(node),
        operator: operator,
        boolean_evidence: boolean_evidence,
        default?: default?,
        returned?: returned?
      }
    end)
  end

  defp dual_representation_fallback?(%Fallback{accesses: accesses}) do
    representations = MapSet.new(accesses, & &1.representation)

    (MapSet.member?(representations, :atom) and MapSet.member?(representations, :string)) or
      (MapSet.member?(representations, :native) and
         (MapSet.member?(representations, :derived_atom) or
            MapSet.member?(representations, :derived_string)))
  end

  defp fallback_contracts(project) do
    project
    |> collect_fallbacks()
    |> Enum.map(&fallback_contract(&1, project))
  end

  defp fallback_contract(%Fallback{} = fallback, project) do
    first = List.first(fallback.accesses)
    variable = origin_variable(project, first.map_origins)
    key = first.key_label
    representations = fallback.accesses |> Enum.map(& &1.representation) |> Enum.uniq()
    source_span = fallback.node.source_span || %{}

    %Contract{
      variable: variable,
      keys: [key],
      location: fallback.location,
      reads: Enum.map(fallback.accesses, &Map.put(&1.location, :key, key)),
      updates: [],
      confidence: :high,
      source: :parameter,
      producer: {:parameter, fallback.function, variable},
      role: classify_role(variable, :parameter),
      key_coverage: 1.0,
      observed_keys: [key],
      unused_keys: [],
      read_count: length(fallback.accesses),
      mutation_count: 0,
      escaped?: false,
      escapes: [],
      consumer: fallback.function,
      file: source_span[:file],
      representations: %{key => representations},
      accesses: fallback.accesses,
      parameter: variable
    }
  end

  defp origin_variable(project, origins) do
    Enum.find_value(origins, fn origin ->
      case Map.get(project.nodes, origin) do
        %{type: :var, meta: %{name: name}} -> name
        _node -> nil
      end
    end)
  end

  defp node_location(%{source_span: span}) when is_map(span) do
    %{line: span[:start_line], column: span[:start_col]}
  end

  defp node_location(_node), do: %{line: nil, column: nil}

  defp collect_file_project_contracts(file, ast, module_definitions, return_shapes) do
    local_contracts = ast |> collect_function_definitions() |> collect_ast_contracts()

    local_contracts
    |> Enum.map(&Map.put(&1, :file, file))
    |> Kernel.++(collect_cross_function_contracts(module_definitions, return_shapes, file))
  end

  defp collect_function_definitions(ast) do
    AST.collect(ast, fn
      {def_kind, _meta, [head, block]}, definitions when def_kind in [:def, :defp] ->
        add_function_definition(head, block, definitions)

      _node, definitions ->
        definitions
    end)
  end

  defp add_function_definition({:when, _meta, [head | _guards]}, block, definitions),
    do: add_function_definition(head, block, definitions)

  defp add_function_definition({name, meta, args}, block, definitions)
       when is_atom(name) and is_list(args) do
    case function_body(block) do
      nil -> definitions
      body -> [%{name: name, arity: length(args), meta: meta, body: body} | definitions]
    end
  end

  defp add_function_definition(_head, _block, definitions), do: definitions

  defp collect_module_definitions(ast) do
    AST.collect(ast, fn
      {:defmodule, _meta, [module_ast, block]}, modules ->
        case module_name(module_ast) do
          {:ok, module} -> collect_module_functions(module, block) ++ modules
          :error -> modules
        end

      _node, modules ->
        modules
    end)
  end

  defp collect_module_functions(module, block) do
    block
    |> function_body()
    |> case do
      nil -> []
      body -> Enum.map(collect_function_definitions(body), &Map.put(&1, :module, module))
    end
  end

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts),
    do: {:ok, Module.concat(parts)}

  defp module_name(_node), do: :error

  defp collect_module_return_shapes(definitions) do
    definitions
    |> Map.new(fn definition ->
      {{definition.module, definition.name, definition.arity}, returned_shape(definition)}
    end)
    |> Enum.reject(fn {_mfa, shape} -> is_nil(shape) end)
    |> Map.new()
  end

  defp function_body(do: body), do: body
  defp function_body([{{:__block__, _meta, [:do]}, body}]), do: body
  defp function_body(_block), do: nil

  defp collect_local_contracts(definitions) do
    Enum.flat_map(definitions, fn definition ->
      definition.body
      |> collect_literal_map_bindings()
      |> build_contracts(definition.body, :local)
    end)
  end

  defp collect_return_contracts(definitions) do
    return_shapes = collect_return_shapes(definitions)

    Enum.flat_map(definitions, fn definition ->
      definition.body
      |> collect_return_value_bindings(return_shapes)
      |> build_contracts(definition.body, :return)
    end)
  end

  defp collect_return_shapes(definitions) do
    definitions
    |> Map.new(fn definition ->
      {{definition.name, definition.arity}, returned_shape(definition)}
    end)
    |> Enum.reject(fn {_mfa, shape} -> is_nil(shape) end)
    |> Map.new()
  end

  defp returned_shape(%{body: {:__block__, _meta, statements}, meta: meta})
       when is_list(statements) do
    bindings = collect_literal_map_bindings({:__block__, [], statements})
    returned_expression_shape(List.last(statements), bindings, meta)
  end

  defp returned_shape(%{body: body, meta: meta}) do
    returned_expression_shape(body, %{}, meta)
  end

  defp returned_expression_shape(expression, bindings, fallback_meta) do
    keys = map_literal_keys(expression)

    cond do
      length(keys) >= @min_keys ->
        %{keys: keys, meta: fallback_meta}

      match?({:ok, _variable}, variable_name(expression)) ->
        returned_variable_shape(expression, bindings)

      true ->
        nil
    end
  end

  defp returned_variable_shape(expression, bindings) do
    {:ok, variable} = variable_name(expression)
    Map.get(bindings, variable)
  end

  defp collect_literal_map_bindings({:__block__, _meta, statements}) do
    Enum.reduce(statements, %{}, &put_literal_map_binding/2)
  end

  defp collect_literal_map_bindings(statement), do: put_literal_map_binding(statement, %{})

  defp put_alias_binding(bindings, var, rhs, meta) do
    {:ok, source_var} = variable_name(rhs)

    if Map.has_key?(bindings, source_var),
      do: Map.put(bindings, var, %{bindings[source_var] | meta: meta}),
      else: bindings
  end

  defp put_literal_map_binding({:=, meta, [{var, _, context}, rhs]}, bindings)
       when is_atom(var) and is_atom(context) do
    keys = map_literal_keys(rhs)

    cond do
      length(keys) >= @min_keys ->
        Map.put(bindings, var, %{keys: keys, meta: meta})

      match?({:ok, _source_var}, variable_name(rhs)) ->
        put_alias_binding(bindings, var, rhs, meta)

      true ->
        bindings
    end
  end

  defp put_literal_map_binding(_statement, bindings), do: bindings

  defp collect_return_value_bindings({:__block__, _meta, statements}, return_shapes) do
    Enum.reduce(statements, %{}, &put_return_value_binding(&1, &2, return_shapes))
  end

  defp collect_return_value_bindings(statement, return_shapes),
    do: put_return_value_binding(statement, %{}, return_shapes)

  defp collect_cross_function_contracts(definitions, return_shapes, file) do
    Enum.flat_map(definitions, fn definition ->
      definition.body
      |> collect_cross_function_bindings(return_shapes)
      |> build_contracts(definition.body, :cross_file_return)
      |> Enum.map(fn contract ->
        contract
        |> Map.put(:file, file)
        |> Map.put(:consumer, {definition.module, definition.name, definition.arity})
      end)
    end)
  end

  defp collect_cross_function_bindings({:__block__, _meta, statements}, return_shapes) do
    Enum.reduce(statements, %{}, &put_cross_function_binding(&1, &2, return_shapes))
  end

  defp collect_cross_function_bindings(statement, return_shapes),
    do: put_cross_function_binding(statement, %{}, return_shapes)

  defp put_cross_function_binding({:=, meta, [{var, _, context}, rhs]}, bindings, return_shapes)
       when is_atom(var) and is_atom(context) do
    cond do
      match?({:ok, _producer}, remote_call(rhs)) ->
        with {:ok, producer} <- remote_call(rhs),
             %{keys: keys} <- Map.get(return_shapes, producer) do
          Map.put(bindings, var, %{keys: keys, meta: meta, producer: producer})
        else
          _other -> bindings
        end

      match?({:ok, _source_var}, variable_name(rhs)) ->
        put_existing_alias_binding(bindings, var, rhs, meta)

      true ->
        bindings
    end
  end

  defp put_cross_function_binding(_statement, bindings, _return_shapes), do: bindings

  defp put_return_value_binding({:=, meta, [{var, _, context}, rhs]}, bindings, return_shapes)
       when is_atom(var) and is_atom(context) do
    cond do
      match?({:ok, _producer}, local_call(rhs)) ->
        with {:ok, producer} <- local_call(rhs),
             %{keys: keys} <- Map.get(return_shapes, producer) do
          Map.put(bindings, var, %{keys: keys, meta: meta, producer: producer})
        else
          _other -> bindings
        end

      match?({:ok, _source_var}, variable_name(rhs)) ->
        put_existing_alias_binding(bindings, var, rhs, meta)

      true ->
        bindings
    end
  end

  defp put_return_value_binding(_statement, bindings, _return_shapes), do: bindings

  defp put_existing_alias_binding(bindings, var, rhs, meta) do
    {:ok, source_var} = variable_name(rhs)

    if Map.has_key?(bindings, source_var),
      do: Map.put(bindings, var, %{bindings[source_var] | meta: meta}),
      else: bindings
  end

  defp local_call({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, {name, length(args)}}

  defp local_call(_node), do: :error

  defp remote_call({{:., _meta, [module_ast, function]}, _call_meta, args})
       when is_atom(function) and is_list(args) do
    case module_name(module_ast) do
      {:ok, module} -> {:ok, {module, function, length(args)}}
      :error -> :error
    end
  end

  defp remote_call(_node), do: :error

  defp variable_name({var, _meta, context}) when is_atom(var) and is_atom(context), do: {:ok, var}
  defp variable_name(_node), do: :error

  defp map_literal_keys({:%{}, _meta, fields}) do
    fields
    |> Enum.flat_map(fn
      {key, _value} when is_atom(key) -> [key]
      {key, _value} when is_binary(key) -> [key]
      _field -> []
    end)
    |> Enum.sort()
  end

  defp map_literal_keys(_node), do: []

  defp build_contracts(bindings, ast, source) do
    if bindings == %{} do
      []
    else
      observations = collect_map_observations(ast, bindings)

      bindings
      |> Enum.flat_map(fn {variable, binding} ->
        build_contract(variable, binding, Map.get(observations, variable, []), source)
      end)
    end
  end

  defp build_contract(variable, binding, observations, source) do
    reads = Enum.filter(observations, &(&1.kind == :read))
    updates = Enum.filter(observations, &(&1.kind == :update))
    escapes = Enum.filter(observations, &(&1.kind == :escape))

    observed_keys =
      observations
      |> Enum.flat_map(fn
        %{key: nil} -> []
        %{key: key} -> [key]
      end)
      |> Enum.uniq()
      |> Enum.sort()

    unused_keys = binding.keys -- observed_keys
    key_coverage = length(observed_keys) / max(length(binding.keys), 1)
    role = classify_role(variable, source)

    if length(observed_keys) >= @min_observations do
      [
        %Contract{
          variable: variable,
          keys: binding.keys,
          location: location(binding.meta),
          reads: Enum.map(reads, &observation_location/1),
          updates: Enum.map(updates, &observation_location/1),
          confidence: confidence(key_coverage, updates),
          source: source,
          producer: Map.get(binding, :producer),
          role: role,
          key_coverage: key_coverage,
          observed_keys: observed_keys,
          unused_keys: unused_keys,
          read_count: length(reads),
          mutation_count: length(updates),
          escaped?: escapes != [],
          escapes: Enum.map(escapes, & &1.call)
        }
      ]
    else
      []
    end
  end

  defp collect_map_observations(ast, bindings) do
    AST.reduce(ast, %{}, &record_observation(&1, bindings, &2))
  end

  defp record_observation(node, bindings, observations) do
    case map_observation(node) do
      {:ok, variable, key, kind, meta} when is_map_key(bindings, variable) ->
        record_known_key_observation(observations, variable, bindings[variable], key, kind, meta)

      _other ->
        record_escape_observation(node, bindings, observations)
    end
  end

  defp record_known_key_observation(observations, variable, binding, key, kind, meta) do
    if key in binding.keys do
      record_observation_for_variable(observations, variable, %{key: key, kind: kind, meta: meta})
    else
      observations
    end
  end

  defp record_escape_observation(node, bindings, observations) do
    case call_args(node) do
      {:ok, meta, args} ->
        call = call_descriptor(node, meta)

        args
        |> Enum.flat_map(&escaped_variables(&1, bindings))
        |> Enum.reduce(observations, fn variable, observations ->
          record_observation_for_variable(observations, variable, %{
            key: nil,
            kind: :escape,
            meta: meta,
            call: call
          })
        end)

      :error ->
        observations
    end
  end

  defp record_observation_for_variable(observations, variable, observation) do
    Map.update(observations, variable, [observation], &[observation | &1])
  end

  defp call_args({name, meta, args})
       when is_atom(name) and is_list(args) and name not in @non_call_forms,
       do: {:ok, meta, args}

  defp call_args({{:., meta, [_target, _function]}, _call_meta, args}) when is_list(args),
    do: {:ok, meta, args}

  defp call_args(_node), do: :error

  defp call_descriptor(node, fallback_meta) do
    case AST.call_descriptor(node) do
      {:ok, descriptor} ->
        descriptor

      :error ->
        %{
          module: nil,
          function: nil,
          arity: nil,
          line: fallback_meta[:line],
          column: fallback_meta[:column]
        }
    end
  end

  defp escaped_variables(arg, bindings) do
    case variable_name(arg) do
      {:ok, variable} when is_map_key(bindings, variable) -> [variable]
      _other -> []
    end
  end

  defp map_observation({{:., meta, [{var, _, context}, key]}, _, []})
       when is_atom(var) and is_atom(context) and is_atom(key),
       do: {:ok, var, key, :read, meta}

  defp map_observation(
         {{:., meta, [{:__aliases__, _, [:Map]}, :get]}, _, [{var, _, context}, key | _]}
       )
       when is_atom(var) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {:ok, var, key, :read, meta}

  defp map_observation(
         {{:., meta, [{:__aliases__, _, [:Map]}, :fetch]}, _, [{var, _, context}, key | _]}
       )
       when is_atom(var) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {:ok, var, key, :read, meta}

  defp map_observation(
         {{:., meta, [{:__aliases__, _, [:Map]}, :put]}, _, [{var, _, context}, key | _]}
       )
       when is_atom(var) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {:ok, var, key, :update, meta}

  defp map_observation({:%{}, meta, [{:|, _, [{var, _, context}, fields]}]})
       when is_atom(var) and is_atom(context) and is_list(fields) do
    case fields do
      [{key, _value} | _] when is_atom(key) or is_binary(key) -> {:ok, var, key, :update, meta}
      _fields -> :error
    end
  end

  defp map_observation(_node), do: :error

  defp classify_role(variable, _source) when variable in @assigns_names, do: :assigns
  defp classify_role(variable, _source) when variable in @accumulator_names, do: :accumulator

  defp classify_role(variable, _source) when variable in @external_payload_names,
    do: :external_payload

  defp classify_role(variable, _source) when variable in @options_names, do: :options
  defp classify_role(_variable, source) when source in [:return, :cross_file_return], do: :domain
  defp classify_role(_variable, _source), do: :unknown

  defp confidence(coverage, updates) do
    cond do
      updates != [] and coverage >= 0.75 -> :high
      coverage >= 0.5 -> :medium
      true -> :low
    end
  end

  defp observation_location(%{key: key, kind: kind, meta: meta}) do
    meta |> location() |> Map.merge(%{key: key, kind: kind})
  end

  defp location(meta), do: %{line: meta[:line], column: meta[:column]}
end
