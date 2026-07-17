defmodule Reach.Evidence.NilParameter do
  @moduledoc "Collects nil-capable parameter uses and their dominating non-nil guards."

  alias Reach.Project.Query

  defmodule Source do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:kind, :file, :line, :caller, context: []]
  end

  defmodule Use do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :operation,
      :target,
      :file,
      :line,
      :column,
      :safe?,
      dominating_guards: [],
      nil_sources: []
    ]
  end

  defmodule Fact do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :function,
      :arity,
      :parameter,
      :parameter_index,
      :file,
      :line,
      nil_sources: [],
      uses: []
    ]
  end

  defmodule Analysis do
    @moduledoc false
    defstruct [:clauses, :requirements, :project, :index, :cfg, :idom, :parents, :arity]
  end

  @strict_external_parameters [
    {Map, :fetch, 0},
    {Map, :fetch!, 0},
    {Map, :get, 0},
    {Map, :get_lazy, 0},
    {Map, :has_key?, 0},
    {Map, :keys, 0},
    {Map, :merge, 0},
    {Map, :put, 0},
    {Map, :replace, 0},
    {Map, :update, 0},
    {Map, :values, 0},
    {:erlang, :map_get, 1}
  ]

  @type_guards [
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_struct,
    :is_tuple
  ]

  @non_nil_pattern_types [:binary, :cons, :list, :map, :struct, :tuple]

  @doc "Collects nilability and guard-dominance facts for project functions."
  @spec collect_project(Reach.Project.t() | map()) :: [Fact.t()]
  def collect_project(%{nodes: nodes, call_graph: %Graph{}} = project) when is_map(nodes) do
    index = Query.function_index(project)
    functions = index.all
    requirements = required_parameters(functions, project.call_graph)

    definition_sources = definition_nil_sources(functions)
    call_sources = call_nil_sources(project, index)

    functions
    |> Enum.flat_map(
      &function_facts(&1, definition_sources, call_sources, requirements, project, index)
    )
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.module, &1.function, &1.parameter_index})
  end

  def collect_project(_incomplete_project), do: []

  defp function_facts(
         function,
         definition_sources,
         call_sources,
         requirements,
         project,
         index
       ) do
    source_parameters = source_parameters(function, definition_sources, call_sources)

    case source_parameters do
      [] -> []
      sources -> facts_for_source_parameters(function, sources, requirements, project, index)
    end
  end

  defp source_parameters(function, definition_sources, call_sources) do
    target = function_id(function)

    function.meta.arity
    |> parameter_indices()
    |> Enum.map(fn parameter_index ->
      sources =
        Map.get(definition_sources, {function.id, parameter_index}, []) ++
          Map.get(call_sources, {target, parameter_index}, [])

      {parameter_index, Enum.uniq(sources)}
    end)
    |> Enum.reject(fn {_parameter_index, sources} -> sources == [] end)
  end

  defp facts_for_source_parameters(function, source_parameters, requirements, project, index) do
    context = analysis_context(function, requirements, project, index)

    Enum.map(source_parameters, fn {parameter_index, sources} ->
      uses =
        context.clauses
        |> Enum.with_index()
        |> Enum.flat_map(&clause_uses(&1, parameter_index, sources, context))

      fact(function, context.clauses, parameter_index, sources, uses)
    end)
  end

  defp analysis_context(function, requirements, project, index) do
    cfg = Reach.ControlFlow.build(function)

    %Analysis{
      clauses: function_clauses(function),
      requirements: requirements,
      project: project,
      index: index,
      cfg: cfg,
      idom: Reach.Dominator.idom(cfg, :entry),
      parents: parent_index(function),
      arity: function.meta.arity
    }
  end

  defp fact(function, clauses, parameter_index, sources, uses) do
    span = function.source_span || %{}

    %Fact{
      module: function.meta.module,
      function: function.meta.name,
      arity: function.meta.arity,
      parameter: parameter_label(clauses, parameter_index, function.meta.arity),
      parameter_index: parameter_index,
      file: span[:file],
      line: span[:start_line],
      nil_sources: Enum.sort_by(sources, &{&1.file || "", &1.line || 0, &1.kind}),
      uses: Enum.sort_by(uses, &{&1.line || 0, &1.column || 0, &1.operation})
    }
  end

  defp clause_uses({clause, clause_index}, parameter_index, sources, context) do
    parameters = clause_parameters(clause, context.arity)
    parameter = Enum.at(parameters, parameter_index)
    applicable_sources = Enum.filter(sources, &source_applies?(&1, parameters, parameter_index))

    case {parameter_name(parameter), applicable_sources} do
      {_name, []} ->
        []

      {nil, _sources} ->
        []

      {name, applicable_sources} ->
        safe_vertices =
          clause
          |> safe_vertices(
            name,
            parameter,
            clause_index,
            context.clauses,
            parameter_index,
            context.arity
          )
          |> Enum.filter(&Graph.has_vertex?(context.cfg, &1))
          |> Enum.uniq()

        clause
        |> collect_uses(name, context.requirements, context.project, context.index)
        |> Enum.map(fn {node, operation, target} ->
          use_sources =
            sources_reaching_use(applicable_sources, node, parameters, context)

          vertex = nearest_cfg_vertex(node.id, context.parents, context.cfg)

          guards =
            safe_vertices
            |> Enum.filter(&dominates?(context.idom, &1, vertex))
            |> Enum.concat(
              lexical_guard_ids(node.id, name, context.parents, context.project.nodes)
            )
            |> Enum.uniq()

          span = node.source_span || %{}

          %Use{
            operation: operation,
            target: target,
            file: span[:file],
            line: span[:start_line],
            column: span[:start_col],
            safe?: guards != [],
            dominating_guards: guards,
            nil_sources: if(guards == [], do: use_sources, else: applicable_sources)
          }
        end)
        |> Enum.reject(&(&1.nil_sources == []))
        |> Enum.uniq_by(&{&1.operation, &1.target, &1.line, &1.column})
    end
  end

  defp sources_reaching_use(sources, node, parameters, context) do
    Enum.filter(
      sources,
      &source_reaches_use?(&1, node.id, parameters, context.parents, context.project.nodes)
    )
  end

  defp source_reaches_use?(source, node_id, parameters, parents, nodes) do
    bindings =
      parameters
      |> Enum.zip(source.context)
      |> Enum.reduce(%{}, fn {parameter, argument}, bindings ->
        case parameter_name(parameter) do
          nil -> bindings
          name -> Map.put(bindings, name, argument)
        end
      end)

    feasible_path?(node_id, bindings, parents, nodes)
  end

  defp feasible_path?(node_id, bindings, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        true

      parent_id ->
        parent = Map.get(nodes, parent_id)
        constraint = path_constraint(parent, node_id)

        constraint_satisfied?(constraint, bindings) and
          feasible_path?(parent_id, bindings, parents, nodes)
    end
  end

  defp path_constraint(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         child_id
       )
       when operator in [:and, :&&, :or, :||] and child_id == right.id do
    {left, operator in [:and, :&&]}
  end

  defp path_constraint(
         %{type: :case, meta: %{desugared_from: kind}, children: [condition | clauses]},
         child_id
       )
       when kind in [:if, :unless] do
    case Enum.find(clauses, &(&1.id == child_id)) do
      %{meta: %{kind: :true_branch}} -> {condition, kind == :if}
      %{meta: %{kind: :false_branch}} -> {condition, kind == :unless}
      _not_a_direct_branch -> nil
    end
  end

  defp path_constraint(_parent, _child_id), do: nil

  defp constraint_satisfied?(nil, _bindings), do: true

  defp constraint_satisfied?({expression, required}, bindings) do
    case evaluate_boolean(expression, bindings) do
      :unknown -> true
      ^required -> true
      _opposite -> false
    end
  end

  defp evaluate_boolean(%{type: :literal, meta: %{value: value}}, _bindings),
    do: value not in [false, nil]

  defp evaluate_boolean(%{type: :var, meta: %{name: name}}, bindings) do
    case Map.get(bindings, name) do
      nil -> :unknown
      argument -> evaluate_boolean(argument, bindings)
    end
  end

  defp evaluate_boolean(
         %{type: :unary_op, meta: %{operator: :not}, children: [child]},
         bindings
       ) do
    case evaluate_boolean(child, bindings) do
      :unknown -> :unknown
      value -> not value
    end
  end

  defp evaluate_boolean(
         %{type: :call, meta: %{function: :is_nil}, children: [argument]},
         bindings
       ) do
    case bound_value(argument, bindings) do
      :unknown -> :unknown
      value -> is_nil(value)
    end
  end

  defp evaluate_boolean(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         bindings
       )
       when operator in [:and, :&&, :or, :||] do
    evaluate_boolean_operator(operator, left, right, bindings)
  end

  defp evaluate_boolean(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         bindings
       )
       when operator in [:==, :===, :!=, :!==] do
    evaluate_comparison(operator, left, right, bindings)
  end

  defp evaluate_boolean(_expression, _bindings), do: :unknown

  defp evaluate_boolean_operator(operator, left, right, bindings) do
    values = {evaluate_boolean(left, bindings), evaluate_boolean(right, bindings)}

    case {operator in [:and, :&&], values} do
      {true, {false, _right}} -> false
      {true, {true, right_value}} -> right_value
      {false, {true, _right}} -> true
      {false, {false, right_value}} -> right_value
      {_and?, _unknown} -> :unknown
    end
  end

  defp evaluate_comparison(operator, left, right, bindings) do
    case {operator, bound_value(left, bindings), bound_value(right, bindings)} do
      {_operator, :unknown, _right} -> :unknown
      {_operator, _left, :unknown} -> :unknown
      {:==, left_value, right_value} -> left_value == right_value
      {:===, left_value, right_value} -> left_value === right_value
      {:!=, left_value, right_value} -> left_value != right_value
      {:!==, left_value, right_value} -> left_value !== right_value
    end
  end

  defp bound_value(%{type: :literal, meta: %{value: value}}, _bindings), do: value

  defp bound_value(%{type: :var, meta: %{name: name}}, bindings) do
    case Map.get(bindings, name) do
      %{type: :literal, meta: %{value: value}} -> value
      _unknown -> :unknown
    end
  end

  defp bound_value(_argument, _bindings), do: :unknown

  defp lexical_guard_ids(node_id, name, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        []

      parent_id ->
        parent = Map.get(nodes, parent_id)
        own = if short_circuit_guards?(parent, node_id, name), do: [parent_id], else: []
        Enum.concat(own, lexical_guard_ids(parent_id, name, parents, nodes))
    end
  end

  defp short_circuit_guards?(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         child_id,
         name
       )
       when operator in [:and, :&&, :or, :||] do
    child_id == right.id and
      guarantees_non_nil?(left, name, operator in [:and, :&&])
  end

  defp short_circuit_guards?(_parent, _child_id, _name), do: false

  defp dominates?(_idom, _guard, nil), do: false
  defp dominates?(idom, guard, vertex), do: Reach.Dominator.dominates?(idom, guard, vertex)

  defp safe_vertices(clause, name, parameter, clause_index, clauses, parameter_index, arity) do
    pattern_vertices = if pattern_excludes_nil?(parameter), do: [clause.id], else: []

    prior_vertices =
      clauses
      |> Enum.take(clause_index)
      |> Enum.with_index()
      |> Enum.filter(fn {prior, _index} ->
        total_nil_clause?(prior, clause, parameter_index, arity)
      end)
      |> Enum.map(fn {_prior, index} -> {:clause_fail, index} end)

    pattern_vertices ++ prior_vertices ++ nested_safe_vertices(clause, name)
  end

  defp nested_safe_vertices(node, name) do
    own =
      case node do
        %{type: :guard, children: [condition | _]} ->
          if guarantees_non_nil?(condition, name, true), do: [node.id], else: []

        %{type: :match, children: [left, right]} ->
          if match_validates_parameter?(left, right, name), do: [node.id], else: []

        %{type: :case, meta: %{desugared_from: kind}, children: [condition | clauses]}
        when kind in [:if, :unless] ->
          conditional_safe_vertices(kind, condition, clauses, name)

        %{type: :case, children: [subject | clauses]} ->
          case_safe_vertices(subject, clauses, name)

        _other ->
          []
      end

    Enum.concat(own, Enum.flat_map(node.children, &nested_safe_vertices(&1, name)))
  end

  defp conditional_safe_vertices(kind, condition, clauses, name) do
    true_clause = Enum.find(clauses, &(&1.meta[:kind] == :true_branch))
    false_clause = Enum.find(clauses, &(&1.meta[:kind] == :false_branch))
    {true_outcome, false_outcome} = if kind == :unless, do: {false, true}, else: {true, false}

    []
    |> maybe_add_vertex(true_clause, guarantees_non_nil?(condition, name, true_outcome))
    |> maybe_add_vertex(false_clause, guarantees_non_nil?(condition, name, false_outcome))
  end

  defp maybe_add_vertex(vertices, nil, _safe?), do: vertices
  defp maybe_add_vertex(vertices, clause, true), do: [clause.id | vertices]
  defp maybe_add_vertex(vertices, _clause, false), do: vertices

  defp case_safe_vertices(subject, clauses, name) do
    if variable?(subject, name) do
      clauses
      |> Enum.with_index()
      |> Enum.flat_map(&case_clause_safe_vertices(&1, clauses))
    else
      []
    end
  end

  defp case_clause_safe_vertices({clause, index}, clauses) do
    pattern = List.first(clause.children)
    prior_nil? = clauses |> Enum.take(index) |> Enum.any?(&case_nil_clause?/1)

    if pattern_excludes_nil?(pattern) or prior_nil?, do: [clause.id], else: []
  end

  defp case_nil_clause?(clause) do
    clause.children |> List.first() |> exact_nil_pattern?()
  end

  defp match_validates_parameter?(left, right, name) do
    (variable?(left, name) and pattern_excludes_nil?(right)) or
      (variable?(right, name) and pattern_excludes_nil?(left))
  end

  defp guarantees_non_nil?(node, name, outcome)

  defp guarantees_non_nil?(%{type: :var, meta: %{name: name}}, name, true), do: true

  defp guarantees_non_nil?(
         %{type: :unary_op, meta: %{operator: :not}, children: [child]},
         name,
         outcome
       ),
       do: guarantees_non_nil?(child, name, not outcome)

  defp guarantees_non_nil?(
         %{type: :call, meta: %{function: :is_nil, arity: 1}, children: [argument]},
         name,
         false
       ),
       do: variable?(argument, name)

  defp guarantees_non_nil?(
         %{type: :call, meta: %{function: function}, children: [argument | _]},
         name,
         true
       )
       when function in @type_guards,
       do: variable?(argument, name)

  defp guarantees_non_nil?(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         name,
         outcome
       )
       when operator in [:==, :===, :!=, :!==] do
    nil_comparison_guarantees?(operator, left, right, name, outcome)
  end

  defp guarantees_non_nil?(
         %{type: :binary_op, meta: %{operator: operator}, children: children},
         name,
         outcome
       )
       when operator in [:and, :&&, :or, :||] do
    boolean_operator_guarantees?(operator, children, name, outcome)
  end

  defp guarantees_non_nil?(_node, _name, _outcome), do: false

  defp nil_comparison_guarantees?(operator, left, right, name, outcome) do
    compares_nil? =
      (variable?(left, name) and exact_nil_pattern?(right)) or
        (variable?(right, name) and exact_nil_pattern?(left))

    equality? = operator in [:==, :===]
    compares_nil? and outcome != equality?
  end

  defp boolean_operator_guarantees?(operator, children, name, outcome) do
    {any?, all?} =
      Enum.reduce(children, {false, true}, fn child, {any?, all?} ->
        guarantee? = guarantees_non_nil?(child, name, outcome)
        {any? or guarantee?, all? and guarantee?}
      end)

    case {operator in [:and, :&&], outcome} do
      {true, true} -> any?
      {true, false} -> all?
      {false, true} -> all?
      {false, false} -> any?
    end
  end

  defp collect_uses(root, name, requirements, project, index) do
    own =
      case unsafe_use(root, name, requirements, project, index) do
        nil -> []
        use -> [use]
      end

    nested =
      Enum.flat_map(root.children, fn child ->
        if child.type == :clause and clause_binds_name?(child, name) do
          []
        else
          collect_uses(child, name, requirements, project, index)
        end
      end)

    own ++ nested
  end

  defp clause_binds_name?(clause, name) do
    clause.children
    |> Enum.take_while(&(&1.type not in [:block, :call, :case, :guard, :literal]))
    |> Enum.any?(&defines_variable?(&1, name))
  end

  defp defines_variable?(%{type: :var, meta: %{name: name, binding_role: :definition}}, name),
    do: true

  defp defines_variable?(node, name), do: Enum.any?(node.children, &defines_variable?(&1, name))

  defp unsafe_use(
         %{type: :call, meta: %{module: module, function: function, kind: kind}} = node,
         name,
         _requirements,
         _project,
         _index
       )
       when module == name and kind in [:field_access, :remote] do
    {node, "#{kind} #{name}.#{function}", nil}
  end

  defp unsafe_use(%{type: :call} = node, name, requirements, project, index) do
    case resolve_call_target(node, project, index) do
      nil ->
        strict_external_use(node, name)

      target ->
        required_project_use(node, name, target, requirements) || strict_external_use(node, name)
    end
  end

  defp unsafe_use(_node, _name, _requirements, _project, _index), do: nil

  defp required_project_use(node, name, target, requirements) do
    node.children
    |> Enum.take(Map.get(node.meta, :arity, 0))
    |> Enum.with_index()
    |> Enum.find_value(&required_argument_use(&1, node, name, target, requirements))
  end

  defp required_argument_use({argument, argument_index}, node, name, target, requirements) do
    if variable?(argument, name) and MapSet.member?(requirements, {target, argument_index}) do
      {node, "call requiring non-nil argument", target}
    end
  end

  defp strict_external_use(%{meta: %{function: function}} = node, name) do
    target = {Map.get(node.meta, :module), function, Map.get(node.meta, :arity, 0)}

    Enum.find_value(
      @strict_external_parameters,
      &external_parameter_use(&1, node, name, target)
    )
  end

  defp strict_external_use(_node, _name), do: nil

  defp external_parameter_use({module, function, parameter_index}, node, name, target) do
    same_target? = module == Map.get(node.meta, :module) and function == node.meta.function
    argument = Enum.at(node.children, parameter_index)

    if same_target? and variable?(argument, name) do
      {node, "call requiring non-nil argument", target}
    end
  end

  defp required_parameters(functions, call_graph) do
    requirements = Enum.reduce(functions, MapSet.new(), &add_function_requirements/2)

    requirements =
      Enum.reduce(functions, requirements, fn function, acc ->
        add_default_arity_requirements(function, acc, requirements)
      end)

    add_virtual_arity_requirements(requirements, functions, call_graph)
  end

  defp add_function_requirements(function, requirements) do
    clauses = function_clauses(function)

    function.meta.arity
    |> parameter_indices()
    |> Enum.reduce(requirements, fn parameter_index, requirements ->
      if function_parameter_rejects_nil?(function, clauses, parameter_index) do
        MapSet.put(requirements, {function_id(function), parameter_index})
      else
        requirements
      end
    end)
  end

  defp function_parameter_rejects_nil?(function, clauses, parameter_index) do
    clauses != [] and
      Enum.all?(clauses, &clause_rejects_nil?(&1, parameter_index, function.meta.arity))
  end

  defp add_default_arity_requirements(function, acc, full_requirements) do
    default_count =
      function
      |> function_clauses()
      |> List.first()
      |> case do
        nil -> 0
        clause -> Enum.count(clause_parameters(clause, function.meta.arity), &default_pattern?/1)
      end

    case default_count do
      0 ->
        acc

      count ->
        minimum_arity = function.meta.arity - count

        Enum.reduce(minimum_arity..(function.meta.arity - 1), acc, fn exposed_arity, acc ->
          add_exposed_arity_requirements(function, exposed_arity, acc, full_requirements)
        end)
    end
  end

  defp add_exposed_arity_requirements(function, exposed_arity, acc, full_requirements) do
    {module, name, _arity} = function_id(function)

    exposed_arity
    |> parameter_indices()
    |> Enum.reduce(acc, fn parameter_index, acc ->
      full_requirement = {function_id(function), parameter_index}

      if MapSet.member?(full_requirements, full_requirement) do
        MapSet.put(acc, {{module, name, exposed_arity}, parameter_index})
      else
        acc
      end
    end)
  end

  defp add_virtual_arity_requirements(requirements, functions, call_graph) do
    defined = MapSet.new(functions, &function_id/1)

    call_graph
    |> Graph.vertices()
    |> Enum.filter(
      &match?(
        {module, function, arity}
        when is_atom(module) and is_atom(function) and is_integer(arity),
        &1
      )
    )
    |> Enum.reject(&MapSet.member?(defined, &1))
    |> Enum.reduce(requirements, fn virtual, acc ->
      add_virtual_requirements(virtual, functions, requirements, acc)
    end)
  end

  defp add_virtual_requirements({module, name, arity} = virtual, functions, requirements, acc) do
    source = nearest_higher_arity(functions, module, name, arity)

    if source do
      arity
      |> parameter_indices()
      |> Enum.reduce(acc, fn parameter_index, acc ->
        copy_virtual_requirement(source, virtual, parameter_index, requirements, acc)
      end)
    else
      acc
    end
  end

  defp nearest_higher_arity(functions, module, name, arity) do
    functions
    |> Enum.filter(fn function ->
      function.meta.module == module and function.meta.name == name and
        function.meta.arity > arity
    end)
    |> Enum.min_by(& &1.meta.arity, fn -> nil end)
  end

  defp copy_virtual_requirement(source, virtual, parameter_index, requirements, acc) do
    if MapSet.member?(requirements, {function_id(source), parameter_index}) do
      MapSet.put(acc, {virtual, parameter_index})
    else
      acc
    end
  end

  defp clause_rejects_nil?(clause, parameter_index, arity) do
    parameter = clause |> clause_parameters(arity) |> Enum.at(parameter_index)

    pattern_excludes_nil?(parameter) or
      case parameter_name(parameter) do
        nil -> false
        name -> Enum.any?(clause_guards(clause), &guarantees_non_nil?(&1, name, true))
      end
  end

  defp definition_nil_sources(functions) do
    Enum.reduce(functions, %{}, &add_function_nil_sources/2)
  end

  defp add_function_nil_sources(function, sources) do
    function
    |> function_clauses()
    |> Enum.reduce(sources, &add_clause_nil_sources(&1, function, &2))
  end

  defp add_clause_nil_sources(clause, function, sources) do
    parameters = clause_parameters(clause, function.meta.arity)

    parameters
    |> Stream.with_index()
    |> Enum.reduce(sources, fn {parameter, index}, sources ->
      add_parameter_nil_source(parameter, index, parameters, function, sources)
    end)
  end

  defp add_parameter_nil_source(parameter, index, parameters, function, sources) do
    case parameter_nil_source(parameter, function, parameters) do
      nil -> sources
      source -> put_source(sources, {function.id, index}, source)
    end
  end

  defp parameter_nil_source(parameter, function, parameters) do
    cond do
      exact_nil_pattern?(parameter) ->
        source(:nil_clause, function, parameters)

      default_nil_pattern?(parameter) ->
        source(:nil_default, function, Enum.map(parameters, &default_context_argument/1))

      true ->
        nil
    end
  end

  defp default_context_argument(parameter), do: default_argument(parameter) || parameter

  defp source(kind, function, context) do
    span = function.source_span || %{}
    %Source{kind: kind, file: span[:file], line: span[:start_line], context: context}
  end

  defp call_nil_sources(project, index) do
    Enum.reduce(project.nodes, %{}, fn
      {_id, %{type: :call} = node}, sources ->
        put_call_nil_sources(node, sources, project, index)

      {_id, _node}, sources ->
        sources
    end)
  end

  defp put_call_nil_sources(node, sources, project, index) do
    case resolve_call_target(node, project, index) do
      nil ->
        sources

      target ->
        node
        |> call_arguments()
        |> Stream.with_index()
        |> Enum.reduce(sources, fn argument, sources ->
          add_call_argument_source(argument, node, target, index, sources)
        end)
    end
  end

  defp add_call_argument_source({argument, parameter_index}, node, target, index, sources) do
    if exact_nil_pattern?(argument) do
      span = node.source_span || %{}

      source = %Source{
        kind: :nil_argument,
        file: span[:file],
        line: span[:start_line],
        caller: Map.get(index.node_to_function, node.id),
        context: call_context(node, target, index)
      }

      put_source(sources, {target, parameter_index}, source)
    else
      sources
    end
  end

  defp call_arguments(node), do: Enum.take(node.children, Map.get(node.meta, :arity, 0))

  defp call_context(node, target, index) do
    arguments = call_arguments(node)

    case Map.get(index.by_module, target, []) do
      [function | _] ->
        Enum.concat(arguments, omitted_default_arguments(function, length(arguments)))

      _missing ->
        arguments
    end
  end

  defp omitted_default_arguments(function, argument_count) do
    function
    |> function_clauses()
    |> List.first()
    |> case do
      nil -> []
      clause -> clause |> clause_parameters(function.meta.arity) |> Enum.drop(argument_count)
    end
    |> Enum.map(&default_argument/1)
    |> Enum.reject(&is_nil/1)
  end

  defp default_argument(%{type: :call, meta: %{function: :\\}, children: [_parameter, default]}),
    do: default

  defp default_argument(_parameter), do: nil

  defp resolve_call_target(%{meta: %{function: function, arity: arity}} = node, project, index)
       when is_atom(function) and is_integer(arity) do
    candidates =
      case Map.get(node.meta, :module) do
        nil -> local_candidates(node, index)
        module -> function_candidates(index, module, node.meta.function, node.meta.arity)
      end

    case Enum.uniq_by(candidates, &function_id/1) do
      [function] -> function_id(function)
      _ambiguous -> call_graph_target(node, project, index)
    end
  end

  defp resolve_call_target(_node, _project, _index), do: nil

  defp local_candidates(node, index) do
    case Map.get(index.node_to_function, node.id) do
      {module, _function, _arity} ->
        function_candidates(index, module, node.meta.function, node.meta.arity)

      nil ->
        Map.get(index.by_name_arity, {node.meta.function, node.meta.arity}, [])
    end
  end

  defp function_candidates(index, module, name, arity) do
    case Map.get(index.by_module, {module, name, arity}, []) do
      [] ->
        index.by_module
        |> Enum.filter(fn
          {{^module, ^name, candidate_arity}, _functions} -> candidate_arity > arity
          {_key, _functions} -> false
        end)
        |> Enum.min_by(
          fn {{_module, _name, candidate_arity}, _functions} -> candidate_arity end,
          fn -> nil end
        )
        |> case do
          nil -> []
          {_key, functions} -> functions
        end

      functions ->
        functions
    end
  end

  defp call_graph_target(node, project, index) do
    with caller when not is_nil(caller) <- Map.get(index.node_to_function, node.id) do
      targets =
        project
        |> Query.all_variants(caller)
        |> Enum.flat_map(&Graph.out_neighbors(project.call_graph, &1))
        |> Enum.filter(fn
          {_module, function, arity} ->
            function == node.meta.function and arity == node.meta.arity

          _other ->
            false
        end)
        |> Enum.uniq()

      case targets do
        [target] -> target
        _ambiguous -> nil
      end
    end
  end

  defp put_source(sources, key, source) do
    Map.update(sources, key, [source], fn existing ->
      if Enum.any?(existing, &(&1 == source)), do: existing, else: [source | existing]
    end)
  end

  defp function_clauses(function), do: Enum.filter(function.children, &(&1.type == :clause))
  defp function_id(function), do: {function.meta.module, function.meta.name, function.meta.arity}

  defp clause_parameters(clause, arity), do: Enum.take(clause.children, arity)

  defp parameter_indices(arity) when arity > 0, do: 0..(arity - 1)
  defp parameter_indices(0), do: []

  defp clause_guards(clause) do
    Enum.filter(clause.children, &(&1.type == :guard))
    |> Enum.flat_map(& &1.children)
  end

  defp parameter_label(clauses, index, arity) do
    Enum.find_value(clauses, "arg#{index + 1}", fn clause ->
      clause
      |> clause_parameters(arity)
      |> Enum.drop(index)
      |> List.first()
      |> parameter_name()
    end)
  end

  defp parameter_name(nil), do: nil
  defp parameter_name(%{type: :var, meta: %{name: name}}), do: name

  defp parameter_name(%{type: :call, meta: %{function: :\\}, children: [parameter | _]}) do
    parameter_name(parameter)
  end

  defp parameter_name(%{type: :match, children: children}) do
    Enum.find_value(children, &parameter_name/1)
  end

  defp parameter_name(_parameter), do: nil

  defp total_nil_clause?(prior_clause, current_clause, parameter_index, arity) do
    prior_parameters = clause_parameters(prior_clause, arity)
    current_parameters = clause_parameters(current_clause, arity)
    current_parameters_tuple = List.to_tuple(current_parameters)

    exact_nil_pattern?(Enum.at(prior_parameters, parameter_index)) and
      clause_guards(prior_clause) == [] and
      prior_parameters
      |> Enum.with_index()
      |> Enum.reject(fn {_pattern, index} -> index == parameter_index end)
      |> Enum.all?(fn {prior_pattern, index} ->
        pattern_covers?(prior_pattern, elem(current_parameters_tuple, index))
      end)
  end

  defp source_applies?(%Source{kind: :nil_default}, _parameters, _parameter_index), do: true

  defp source_applies?(%Source{kind: kind, context: context}, parameters, parameter_index) do
    context
    |> Enum.zip(parameters)
    |> Enum.with_index()
    |> Enum.reject(fn {_patterns, index} -> index == parameter_index end)
    |> Enum.all?(fn {{source_pattern, current_pattern}, _index} ->
      case kind do
        :nil_clause -> pattern_covers?(source_pattern, current_pattern)
        :nil_argument -> patterns_overlap?(source_pattern, current_pattern)
      end
    end)
  end

  defp pattern_covers?(prior, %{type: :match, children: children}) do
    Enum.any?(children, &pattern_covers?(prior, &1))
  end

  defp pattern_covers?(%{type: :match, children: children}, current) do
    Enum.any?(children, &pattern_covers?(&1, current))
  end

  defp pattern_covers?(%{type: :map} = prior, %{type: :map} = current),
    do: map_pattern_covers?(prior, current)

  defp pattern_covers?(
         %{type: :struct, meta: prior_meta} = prior,
         %{
           type: :struct,
           meta: current_meta
         } = current
       ) do
    prior_meta[:name] == current_meta[:name] and map_pattern_covers?(prior, current)
  end

  defp pattern_covers?(prior, current) do
    catch_all_pattern?(prior) or pattern_signature(prior) == pattern_signature(current)
  end

  defp map_pattern_covers?(prior, current) do
    current_fields = Map.new(current.children, &map_field_signature/1)

    Enum.all?(prior.children, fn field ->
      {key, value} = map_field_signature(field)

      case Map.fetch(current_fields, key) do
        {:ok, current_value} -> pattern_covers?(value, current_value)
        :error -> false
      end
    end)
  end

  defp map_field_signature(%{type: :map_field, children: [key, value]}) do
    {pattern_signature(key), value}
  end

  defp map_field_signature(node), do: {pattern_signature(node), node}

  defp patterns_overlap?(source, current) do
    cond do
      dynamic_argument?(source) ->
        true

      catch_all_overlap?(source, current) ->
        true

      pattern_coverage_overlap?(source, current) ->
        true

      same_literal?(source, current) ->
        true

      true ->
        source.type == current.type and source.type in @non_nil_pattern_types
    end
  end

  defp dynamic_argument?(node) do
    node.type not in [:binary, :cons, :list, :literal, :map, :struct, :tuple, :var]
  end

  defp catch_all_overlap?(source, current),
    do: catch_all_pattern?(source) or catch_all_pattern?(current)

  defp pattern_coverage_overlap?(source, current),
    do: pattern_covers?(source, current) or pattern_covers?(current, source)

  defp same_literal?(%{type: :literal, meta: source}, %{type: :literal, meta: current}),
    do: source[:value] == current[:value]

  defp same_literal?(_source, _current), do: false

  defp pattern_signature(%{type: :var}), do: :variable

  defp pattern_signature(%{type: type, meta: meta, children: children}) do
    relevant_meta = Map.take(meta, [:name, :value, :function, :operator])
    {type, relevant_meta, Enum.map(children, &pattern_signature/1)}
  end

  defp pattern_signature(nil), do: nil

  defp catch_all_pattern?(%{type: :var}), do: true

  defp catch_all_pattern?(%{type: :call, meta: %{function: :\\}, children: [parameter | _]}),
    do: catch_all_pattern?(parameter)

  defp catch_all_pattern?(_pattern), do: false

  defp pattern_excludes_nil?(nil), do: false
  defp pattern_excludes_nil?(%{type: :literal, meta: %{value: nil}}), do: false
  defp pattern_excludes_nil?(%{type: :literal}), do: true
  defp pattern_excludes_nil?(%{type: :var}), do: false

  defp pattern_excludes_nil?(%{type: type}) when type in @non_nil_pattern_types,
    do: true

  defp pattern_excludes_nil?(%{type: :match, children: children}),
    do: Enum.any?(children, &pattern_excludes_nil?/1)

  defp pattern_excludes_nil?(%{type: :call, meta: %{function: :\\}}), do: false
  defp pattern_excludes_nil?(_pattern), do: false

  defp default_pattern?(%{type: :call, meta: %{function: :\\}}), do: true
  defp default_pattern?(_pattern), do: false

  defp default_nil_pattern?(%{
         type: :call,
         meta: %{function: :\\},
         children: [_parameter, default]
       }),
       do: exact_nil_pattern?(default)

  defp default_nil_pattern?(_pattern), do: false

  defp exact_nil_pattern?(%{type: :literal, meta: %{value: nil}}), do: true
  defp exact_nil_pattern?(_pattern), do: false

  defp variable?(%{type: :var, meta: %{name: name}}, name), do: true
  defp variable?(_node, _name), do: false

  defp parent_index(root), do: parent_index(root, nil, %{})

  defp parent_index(node, parent, index) do
    index = if parent, do: Map.put(index, node.id, parent.id), else: index
    Enum.reduce(node.children, index, &parent_index(&1, node, &2))
  end

  defp nearest_cfg_vertex(nil, _parents, _cfg), do: nil

  defp nearest_cfg_vertex(node_id, parents, cfg) do
    if Graph.has_vertex?(cfg, node_id) do
      node_id
    else
      nearest_cfg_vertex(Map.get(parents, node_id), parents, cfg)
    end
  end
end
