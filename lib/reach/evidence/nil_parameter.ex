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
      :bare_parameter?,
      :parameter_guarded?,
      :companion_restricted?,
      :conditional?,
      :project_target?,
      :literal_companion_gate?,
      dominating_guards: [],
      nil_sources: []
    ]
  end

  defmodule Fact do
    @moduledoc "Evidence that a nil-capable parameter can reach a strict use."
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :function,
      :arity,
      :parameter,
      :parameter_index,
      :visibility,
      :recursive?,
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
    requirements = required_parameters(index, project.call_graph)

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

    source_parameters
    |> Enum.map(fn {parameter_index, sources} ->
      uses =
        context.clauses
        |> Enum.with_index()
        |> Enum.flat_map(&clause_uses(&1, parameter_index, sources, context))

      fact(function, context.clauses, parameter_index, sources, uses)
    end)
    |> Enum.reject(&(&1.parameter == :_))
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
      visibility: if(function.meta[:kind] == :defp, do: :private, else: :public),
      recursive?: recursive_function?(function),
      file: span[:file],
      line: span[:start_line],
      nil_sources: Enum.sort_by(sources, &{&1.file || "", &1.line || 0, &1.kind}),
      uses: Enum.sort_by(uses, &{&1.line || 0, &1.column || 0, &1.operation})
    }
  end

  defp clause_uses({clause, clause_index}, parameter_index, sources, context) do
    parameters = clause_parameters(clause, context.arity)
    parameter = Enum.at(parameters, parameter_index)

    applicable_sources =
      applicable_sources(sources, parameters, parameter_index, clause_index, context)

    case {parameter_name(parameter), applicable_sources} do
      {_name, []} ->
        []

      {nil, _sources} ->
        []

      {name, sources} ->
        analyzed_clause_uses(
          clause,
          clause_index,
          parameter_index,
          parameter,
          name,
          parameters,
          sources,
          context
        )
    end
  end

  defp applicable_sources(sources, parameters, parameter_index, clause_index, context) do
    prior_clauses = Enum.take(context.clauses, clause_index)

    Enum.filter(sources, fn source ->
      source_applies?(source, parameters, parameter_index) and
        not source_shadowed_by_prior_clause?(
          source,
          parameters,
          parameter_index,
          prior_clauses,
          context.arity
        )
    end)
  end

  defp analyzed_clause_uses(
         clause,
         clause_index,
         parameter_index,
         parameter,
         name,
         parameters,
         sources,
         context
       ) do
    analysis = %{
      clause: clause,
      context: context,
      name: name,
      parameter: parameter,
      parameter_index: parameter_index,
      parameters: parameters,
      prior_nil_clause?: prior_nil_clause?(clause, clause_index, parameter_index, context),
      rebindings:
        clause
        |> body_rebindings(name, context.arity)
        |> Enum.filter(&Graph.has_vertex?(context.cfg, &1)),
      safe_vertices:
        safe_vertices(
          clause,
          name,
          parameter,
          clause_index,
          context.clauses,
          parameter_index,
          context.arity
        ),
      sources: sources
    }

    clause
    |> collect_uses(name, context.requirements, context.project, context.index)
    |> Enum.flat_map(&build_use(&1, analysis))
    |> Enum.reject(&(&1.nil_sources == []))
    |> Enum.uniq_by(&{&1.operation, &1.target, &1.line, &1.column})
  end

  defp prior_nil_clause?(clause, clause_index, parameter_index, context) do
    context.clauses
    |> Enum.take(clause_index)
    |> Enum.any?(&total_nil_clause?(&1, clause, parameter_index, context.arity))
  end

  defp build_use({node, operation, target}, analysis) do
    vertex = nearest_cfg_vertex(node.id, analysis.context.parents, analysis.context.cfg)

    if ignored_use?(node, vertex, analysis) do
      []
    else
      guards = guarding_vertices(node, vertex, analysis)

      use_sources =
        sources_reaching_use(analysis.sources, node, analysis.parameters, analysis.context)

      span = node.source_span || %{}
      safe? = analysis.prior_nil_clause? or guards != []

      [
        %Use{
          operation: operation,
          target: target,
          file: span[:file],
          line: span[:start_line],
          column: span[:start_col],
          safe?: safe?,
          bare_parameter?: analysis.parameter.type == :var,
          parameter_guarded?: clause_guarded?(analysis.clause, analysis.name),
          companion_restricted?:
            companion_restricted?(
              analysis.clause,
              analysis.parameters,
              analysis.parameter_index,
              analysis.name
            ),
          conditional?:
            conditional_use?(
              node.id,
              analysis.clause.id,
              analysis.context.parents,
              analysis.context.project.nodes
            ),
          project_target?:
            not is_nil(target) and Map.has_key?(analysis.context.index.by_module, target),
          literal_companion_gate?:
            literal_companion_gate?(
              node.id,
              analysis.clause.id,
              analysis.name,
              analysis.context.parents,
              analysis.context.project.nodes
            ),
          dominating_guards: guards,
          nil_sources: if(safe?, do: analysis.sources, else: use_sources)
        }
      ]
    end
  end

  defp ignored_use?(node, vertex, analysis) do
    rebound_before_use?(node.id, vertex, analysis.rebindings, analysis.context) or
      with_rebound_before_use?(
        node.id,
        analysis.name,
        analysis.context.parents,
        analysis.context.project.nodes
      ) or
      inside_guard?(node.id, analysis.context.parents, analysis.context.project.nodes)
  end

  defp guarding_vertices(node, vertex, analysis) do
    analysis.safe_vertices
    |> Enum.filter(&Graph.has_vertex?(analysis.context.cfg, &1))
    |> Enum.uniq()
    |> Enum.filter(&dominates?(analysis.context.idom, &1, vertex))
    |> Enum.concat(
      lexical_guard_ids(
        node.id,
        analysis.name,
        analysis.context.parents,
        analysis.context.project.nodes
      )
    )
    |> Enum.uniq()
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
      %{meta: %{kind: :true_branch}} -> {condition, true}
      %{meta: %{kind: :false_branch}} -> {condition, false}
      _not_a_direct_branch -> nil
    end
  end

  defp path_constraint(%{type: :case, children: [subject | clauses]}, child_id) do
    case Enum.find_index(clauses, &(&1.id == child_id)) do
      nil ->
        nil

      index ->
        clause = Enum.at(clauses, index)
        pattern = List.first(clause.children)
        prior_patterns = clauses |> Enum.take(index) |> Enum.map(&List.first(&1.children))
        {:case_clause, subject, pattern, prior_patterns}
    end
  end

  defp path_constraint(_parent, _child_id), do: nil

  defp constraint_satisfied?(nil, _bindings), do: true

  defp constraint_satisfied?({:case_clause, subject, pattern, prior_patterns}, bindings) do
    case bound_value(subject, bindings) do
      :unknown ->
        true

      value ->
        pattern_accepts_value?(pattern, value) and
          Enum.all?(prior_patterns, &(not pattern_accepts_value?(&1, value)))
    end
  end

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

  defp pattern_accepts_value?(%{type: :literal, meta: %{value: pattern}}, value),
    do: pattern == value

  defp pattern_accepts_value?(%{type: :var}, _value), do: true

  defp pattern_accepts_value?(%{type: :match, children: children}, value),
    do: Enum.any?(children, &pattern_accepts_value?(&1, value))

  defp pattern_accepts_value?(%{type: type}, nil) when type in @non_nil_pattern_types,
    do: false

  defp pattern_accepts_value?(_pattern, _value), do: true

  defp lexical_guard_ids(node_id, name, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        []

      parent_id ->
        parent = Map.get(nodes, parent_id)
        own = if lexical_non_nil_guard?(parent, node_id, name), do: [parent_id], else: []
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

  defp lexical_non_nil_guard?(parent, child_id, name) do
    short_circuit_guards?(parent, child_id, name) or
      conditional_branch_guards?(parent, child_id, name) or
      cond_branch_guards?(parent, child_id, name) or
      case_branch_guards?(parent, child_id, name)
  end

  defp conditional_branch_guards?(
         %{type: :case, meta: %{desugared_from: kind}, children: [condition | clauses]},
         child_id,
         name
       )
       when kind in [:if, :unless] do
    case Enum.find(clauses, &(&1.id == child_id)) do
      %{meta: %{kind: :true_branch}} -> guarantees_non_nil?(condition, name, true)
      %{meta: %{kind: :false_branch}} -> guarantees_non_nil?(condition, name, false)
      _not_a_branch -> false
    end
  end

  defp conditional_branch_guards?(_parent, _child_id, _name), do: false

  defp cond_branch_guards?(
         %{type: :case, meta: %{desugared_from: :cond}, children: clauses},
         child_id,
         name
       ) do
    case Enum.find_index(clauses, &(&1.id == child_id)) do
      nil ->
        false

      index ->
        selected = clauses |> Enum.at(index) |> then(&List.first(&1.children))

        guarantees_non_nil?(selected, name, true) or
          clauses
          |> Enum.take(index)
          |> Enum.any?(fn clause ->
            condition = List.first(clause.children)
            guarantees_non_nil?(condition, name, false)
          end)
    end
  end

  defp cond_branch_guards?(_parent, _child_id, _name), do: false

  defp case_branch_guards?(
         %{type: :case, meta: meta, children: [subject | clauses]},
         child_id,
         name
       )
       when not is_map_key(meta, :desugared_from) do
    if variable?(subject, name) do
      case Enum.find_index(clauses, &(&1.id == child_id)) do
        nil -> false
        index -> case_clause_safe?({Enum.at(clauses, index), index}, clauses)
      end
    else
      false
    end
  end

  defp case_branch_guards?(_parent, _child_id, _name), do: false

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

  defp conditional_safe_vertices(_kind, condition, clauses, name) do
    true_clause = Enum.find(clauses, &(&1.meta[:kind] == :true_branch))
    false_clause = Enum.find(clauses, &(&1.meta[:kind] == :false_branch))

    []
    |> maybe_add_vertex(true_clause, guarantees_non_nil?(condition, name, true))
    |> maybe_add_vertex(false_clause, guarantees_non_nil?(condition, name, false))
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

  defp case_clause_safe_vertices({clause, _index} = indexed_clause, clauses) do
    if case_clause_safe?(indexed_clause, clauses), do: [clause.id], else: []
  end

  defp case_clause_safe?({clause, index}, clauses) do
    pattern = List.first(clause.children)
    prior_nil? = clauses |> Enum.take(index) |> Enum.any?(&case_nil_clause?/1)
    pattern_excludes_nil?(pattern) or prior_nil?
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

  defp guarantees_nil?(
         %{type: :call, meta: %{function: :is_nil, arity: 1}, children: [argument]},
         name,
         true
       ),
       do: variable?(argument, name)

  defp guarantees_nil?(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         name,
         outcome
       )
       when operator in [:==, :===, :!=, :!==] do
    compares_nil? =
      (variable?(left, name) and exact_nil_pattern?(right)) or
        (variable?(right, name) and exact_nil_pattern?(left))

    equality? = operator in [:==, :===]
    compares_nil? and outcome == equality?
  end

  defp guarantees_nil?(_node, _name, _outcome), do: false

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

  defp clause_guarded?(clause, name),
    do: Enum.any?(clause_guards(clause), &variable_occurs?(&1, name))

  defp companion_restricted?(clause, parameters, parameter_index, _name) do
    parameters
    |> Enum.with_index()
    |> Enum.reject(fn {_parameter, index} -> index == parameter_index end)
    |> Enum.any?(fn {parameter, _index} -> not catch_all_pattern?(parameter) end) or
      clause_guards(clause) != []
  end

  defp variable_occurs?(%{type: :var, meta: %{name: name}}, name), do: true
  defp variable_occurs?(node, name), do: Enum.any?(node.children, &variable_occurs?(&1, name))

  defp conditional_use?(node_id, clause_id, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        false

      ^clause_id ->
        false

      parent_id ->
        parent = Map.get(nodes, parent_id)

        parent.type in [:case, :fn, :comprehension] or
          conditional_use?(parent_id, clause_id, parents, nodes)
    end
  end

  defp literal_companion_gate?(node_id, clause_id, name, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        false

      ^clause_id ->
        false

      parent_id ->
        parent = Map.get(nodes, parent_id)

        case parent do
          %{type: :case, meta: %{desugared_from: kind}, children: [condition | _]}
          when kind in [:if, :unless] ->
            literal_comparison_on_other?(condition, name) or
              literal_companion_gate?(parent_id, clause_id, name, parents, nodes)

          _other ->
            literal_companion_gate?(parent_id, clause_id, name, parents, nodes)
        end
    end
  end

  defp literal_comparison_on_other?(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]},
         name
       )
       when operator in [:==, :===] do
    (left.type == :var and left.meta[:name] != name and right.type == :literal) or
      (right.type == :var and right.meta[:name] != name and left.type == :literal)
  end

  defp literal_comparison_on_other?(_condition, _name), do: false

  defp body_rebindings(clause, name, arity) do
    clause.children
    |> Enum.drop(arity)
    |> Enum.flat_map(&Reach.IR.all_nodes/1)
    |> Enum.flat_map(fn
      %{type: :match, children: [left, right]} = match ->
        if defines_variable?(left, name) and not variable?(right, name),
          do: [match.id],
          else: []

      _node ->
        []
    end)
  end

  defp rebound_before_use?(node_id, vertex, rebindings, context) do
    Enum.any?(rebindings, fn rebind ->
      dominates?(context.idom, rebind, vertex) and
        not ancestor?(rebind, node_id, context.parents)
    end)
  end

  defp with_rebound_before_use?(node_id, name, parents, nodes) do
    case enclosing_with_child(node_id, parents, nodes) do
      {_with_node, %{meta: %{kind: :else_clause}}} ->
        false

      {%{children: children}, child} ->
        children
        |> Enum.take_while(&(&1.id != child.id))
        |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :with_clause))
        |> Enum.any?(fn clause ->
          clause.children |> List.first() |> pattern_binds_name?(name)
        end)

      nil ->
        false
    end
  end

  defp enclosing_with_child(node_id, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        nil

      parent_id ->
        case Map.get(nodes, parent_id) do
          %{type: :case, meta: %{desugared_from: :with}} = with_node ->
            {with_node, Map.get(nodes, node_id)}

          _other ->
            enclosing_with_child(parent_id, parents, nodes)
        end
    end
  end

  defp pattern_binds_name?(nil, _name), do: false
  defp pattern_binds_name?(%{type: :var, meta: %{name: name}}, name), do: true

  defp pattern_binds_name?(node, name),
    do: Enum.any?(node.children, &pattern_binds_name?(&1, name))

  defp inside_guard?(node_id, parents, nodes) do
    case Map.get(parents, node_id) do
      nil ->
        false

      parent_id ->
        Map.get(nodes, parent_id).type == :guard or inside_guard?(parent_id, parents, nodes)
    end
  end

  defp ancestor?(ancestor_id, node_id, parents) do
    case Map.get(parents, node_id) do
      ^ancestor_id -> true
      nil -> false
      parent_id -> ancestor?(ancestor_id, parent_id, parents)
    end
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
         %{
           type: :call,
           meta: %{module: module, function: function, kind: kind, arity: arity},
           children: [receiver | _] = children
         } = node,
         name,
         _requirements,
         _project,
         _index
       )
       when module == name and kind in [:field_access, :remote] do
    if length(children) > arity and variable?(receiver, name),
      do: {node, "#{kind} #{name}.#{function}", nil}
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

  defp required_parameters(index, call_graph) do
    requirements =
      index.all
      |> Enum.group_by(&function_id/1)
      |> Enum.reduce(MapSet.new(), &add_function_requirements/2)

    requirements =
      Enum.reduce(index.all, requirements, fn function, acc ->
        add_default_arity_requirements(function, acc, requirements)
      end)

    add_virtual_arity_requirements(requirements, index, call_graph)
  end

  defp add_function_requirements({function_id, functions}, requirements) do
    arity = function_id |> elem(2)

    arity
    |> parameter_indices()
    |> Enum.reduce(requirements, fn parameter_index, requirements ->
      rejects_nil? =
        Enum.all?(functions, fn function ->
          function_parameter_rejects_nil?(
            function,
            function_clauses(function),
            parameter_index
          )
        end)

      if rejects_nil?,
        do: MapSet.put(requirements, {function_id, parameter_index}),
        else: requirements
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

  defp add_virtual_arity_requirements(requirements, index, call_graph) do
    defined = MapSet.new(index.all, &function_id/1)

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
      add_virtual_requirements(virtual, index, requirements, acc)
    end)
  end

  defp add_virtual_requirements({module, name, arity} = virtual, index, requirements, acc) do
    source = nearest_higher_arity(index, module, name, arity)

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

  defp nearest_higher_arity(index, module, name, arity) do
    index.by_module_name
    |> Map.get({module, name}, [])
    |> Enum.find(&(&1.meta.arity > arity))
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
        |> call_argument_pairs(target, index)
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

  defp call_arguments(node) do
    arity = Map.get(node.meta, :arity, 0)
    Enum.take(node.children, -arity)
  end

  defp call_argument_pairs(node, target, index) do
    arguments = call_arguments(node)

    case Map.get(index.by_module, target, []) do
      [function | _] ->
        function
        |> supplied_parameter_indices(length(arguments))
        |> Enum.zip(arguments)
        |> Enum.map(fn {parameter_index, argument} -> {argument, parameter_index} end)

      _missing ->
        Enum.with_index(arguments)
    end
  end

  defp call_context(node, target, index) do
    arguments = call_arguments(node)

    case Map.get(index.by_module, target, []) do
      [function | _] ->
        supplied =
          function
          |> supplied_parameter_indices(length(arguments))
          |> Enum.zip(arguments)
          |> Map.new()

        defaults = default_arguments_by_index(function)

        function.meta.arity
        |> parameter_indices()
        |> Enum.map(fn parameter_index ->
          Map.get(supplied, parameter_index) || Map.get(defaults, parameter_index)
        end)

      _missing ->
        arguments
    end
  end

  defp supplied_parameter_indices(function, argument_count) do
    omitted_count = max(function.meta.arity - argument_count, 0)

    defaults = default_arguments_by_index(function)

    omitted =
      function.meta.arity
      |> parameter_indices()
      |> Enum.reverse()
      |> Stream.filter(&Map.has_key?(defaults, &1))
      |> Enum.take(omitted_count)

    function.meta.arity
    |> parameter_indices()
    |> Enum.reject(&(&1 in omitted))
  end

  defp default_arguments_by_index(function) do
    function
    |> function_clauses()
    |> List.first()
    |> case do
      nil -> []
      clause -> clause_parameters(clause, function.meta.arity)
    end
    |> Stream.with_index()
    |> Enum.reduce(%{}, fn {parameter, index}, defaults ->
      case default_argument(parameter) do
        nil -> defaults
        default -> Map.put(defaults, index, default)
      end
    end)
  end

  defp default_argument(%{type: :call, meta: %{function: :\\}, children: [_parameter, default]}),
    do: default

  defp default_argument(_parameter), do: nil

  defp resolve_call_target(%{meta: %{function: function, arity: arity}} = node, project, index)
       when is_atom(function) and is_integer(arity) do
    if dynamic_receiver_call?(node) do
      nil
    else
      resolved_call_target(node, project, index)
    end
  end

  defp resolve_call_target(_node, _project, _index), do: nil

  defp dynamic_receiver_call?(%{children: children, meta: %{arity: arity}}),
    do: length(children) > arity

  defp resolved_call_target(node, project, index) do
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
      [] -> higher_arity_candidates(index, module, name, arity)
      functions -> functions
    end
  end

  defp higher_arity_candidates(index, module, name, arity) do
    index.by_module_name
    |> Map.get({module, name}, [])
    |> Enum.find(&(&1.meta.arity > arity))
    |> case do
      nil -> []
      function -> Map.get(index.by_module, function_id(function), [])
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

  defp recursive_function?(function) do
    Enum.any?(Reach.IR.all_nodes(function), fn
      %{type: :call, meta: %{module: nil, function: name, arity: arity}} ->
        name == function.meta.name and arity == function.meta.arity

      _node ->
        false
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
  defp parameter_name(%{type: :var, meta: %{name: :_}}), do: nil
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

    nil_clause_parameter?(
      Enum.at(prior_parameters, parameter_index),
      prior_clause,
      current_clause
    ) and
      prior_parameters
      |> Enum.with_index()
      |> Enum.reject(fn {_pattern, index} -> index == parameter_index end)
      |> Enum.all?(fn {prior_pattern, index} ->
        pattern_covers?(prior_pattern, elem(current_parameters_tuple, index))
      end)
  end

  defp nil_clause_parameter?(parameter, prior_clause, current_clause) do
    prior_guards = clause_guards(prior_clause)
    current_guard_signatures = current_clause |> clause_guards() |> Enum.map(&pattern_signature/1)

    cond do
      exact_nil_pattern?(parameter) ->
        prior_guards == [] or
          Enum.all?(prior_guards, &(pattern_signature(&1) in current_guard_signatures))

      name = parameter_name(parameter) ->
        {nil_guards, companion_guards} =
          Enum.split_with(prior_guards, &guarantees_nil?(&1, name, true))

        nil_guards != [] and
          Enum.all?(companion_guards, &(pattern_signature(&1) in current_guard_signatures))

      true ->
        false
    end
  end

  defp source_shadowed_by_prior_clause?(
         source,
         current_parameters,
         parameter_index,
         prior_clauses,
         arity
       ) do
    source_context = List.to_tuple(source.context)

    forced_values =
      current_parameters
      |> Enum.with_index()
      |> Enum.map(fn {current, index} ->
        current_value = exact_pattern_value(current)
        source_value = source_context |> tuple_element(index) |> exact_pattern_value()

        cond do
          index == parameter_index -> nil
          current_value != :unknown -> current_value
          source_value != :unknown -> source_value
          true -> :unknown
        end
      end)

    Enum.any?(prior_clauses, &clause_accepts_forced_values?(&1, forced_values, arity))
  end

  defp clause_accepts_forced_values?(clause, forced_values, arity) do
    parameters = clause_parameters(clause, arity)

    repeated_variables =
      parameters
      |> Enum.with_index()
      |> Enum.group_by(fn {parameter, _index} -> parameter_name(parameter) end)
      |> Enum.reject(fn {name, entries} -> is_nil(name) or length(entries) < 2 end)

    forced_values_tuple = List.to_tuple(forced_values)

    clause_guards(clause) == [] and repeated_variables != [] and
      Enum.all?(Enum.zip(parameters, forced_values), fn
        {%{type: :literal} = pattern, value} -> exact_pattern_value(pattern) == value
        {%{type: :var}, _value} -> true
        {_pattern, _value} -> false
      end) and
      Enum.all?(repeated_variables, fn {_name, entries} ->
        values = Enum.map(entries, fn {_parameter, index} -> elem(forced_values_tuple, index) end)
        :unknown not in values and Enum.uniq(values) |> length() == 1
      end)
  end

  defp tuple_element(tuple, index) when index < tuple_size(tuple), do: elem(tuple, index)
  defp tuple_element(_tuple, _index), do: nil

  defp exact_pattern_value(%{type: :literal, meta: %{value: value}}), do: value
  defp exact_pattern_value(_pattern), do: :unknown

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

  defp dynamic_argument?(nil), do: true

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

  defp exact_nil_pattern?(%{type: :match, children: children}),
    do: Enum.any?(children, &exact_nil_pattern?/1)

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
