# Writing Custom Smells

Reach ships with built-in smell checks, but projects often have local rules that are too specific to belong in Reach itself: forbidden internal APIs, deprecated wrappers, project-specific data contracts, migration rules, or architectural conventions that are easier to express against Reach's IR than with text search.

Custom smells let a consuming project add those rules to `mix reach.check --smells`.

## When to write a custom smell

Use a custom smell when the rule is:

- specific to your application or organization
- structural enough that text search is too noisy
- useful in CI as an advisory or strict gate
- easier to express with modules, calls, source spans, effects, or Reach graph data

For simple dependency boundaries, prefer `.reach.exs` architecture policy first. For framework semantics that should benefit many users, prefer a Reach plugin. For local lint-style rules, custom smells are the right fit.

## Register a custom check

Add the check module to your application and list it in `.reach.exs`:

```elixir
# .reach.exs
[
  smells: [
    strict: true,
    custom_checks: [MyApp.ReachSmells.NoFoo]
  ]
]
```

Reach validates that every listed module implements `Reach.Smell.Check`. Custom findings participate in strict mode and baseline filtering just like built-in findings.

## Minimal custom smell

A smell check implements `Reach.Smell.Check` and returns a list of `Reach.Smell.Finding` structs. Checks may also expose `kinds/0`; Reach's corpus scan tooling uses it to run selected checks without executing unrelated smell modules.

```elixir
defmodule MyApp.ReachSmells.NoFoo do
  @behaviour Reach.Smell.Check

  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:my_app_no_foo]

  @impl true
  def run(project) do
    for {_id, node} <- project.nodes,
        node.type == :call,
        node.meta[:module] == MyApp.Foo do
      Finding.new(
        kind: :my_app_no_foo,
        message: "Use MyApp.Bar instead of MyApp.Foo",
        location: location(node)
      )
    end
  end

  defp location(%{source_span: %{file: file, start_line: line}}), do: "#{file}:#{line}"
  defp location(_node), do: "unknown"
end
```

Run it:

```bash
mix reach.check --smells
mix reach.check --smells --strict
```

## Finding fields

`Reach.Smell.Finding.new/1` accepts these common fields:

```elixir
Finding.new(
  kind: :my_app_no_foo,
  message: "Use MyApp.Bar instead of MyApp.Foo",
  location: "lib/my_app/foo.ex:12",
  confidence: :high,
  evidence: ["lib/my_app/foo.ex:12", "lib/my_app/bar.ex:18"]
)
```

Use stable, namespaced `kind` atoms for project-local rules, such as `:my_app_no_foo` or `:billing_deprecated_money_api`. The finding kind is shown in JSON output and contributes to baseline fingerprints.

`location` should be either `"unknown"` or a `file:line` string. Baselines and terminal output are most useful when every finding points to the primary source location.

## Walking the project

The `project` argument is the loaded Reach project. The most direct API is `project.nodes`, a map of node IDs to IR nodes.

```elixir
for {_id, node} <- project.nodes,
    node.type == :call,
    node.meta[:module] == LegacyAPI do
  # emit a finding
end
```

Useful node fields:

- `node.type` — IR node type, such as `:module_def`, `:function_def`, `:call`, `:var`, `:literal`, `:match`
- `node.meta` — node-specific metadata, such as `:module`, `:function`, `:arity`, `:name`, or `:kind`
- `node.children` — nested IR nodes
- `node.source_span` — source location metadata, usually `%{file: ..., start_line: ...}`

## Function-scoped checks

For checks that inspect each function body, use Reach's IR traversal helpers:

```elixir
defmodule MyApp.ReachSmells.NoDebugCalls do
  @behaviour Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding

  @impl true
  def run(project) do
    project.nodes
    |> Enum.flat_map(fn
      {_id, %{type: :function_def} = function} -> debug_findings(function)
      _entry -> []
    end)
  end

  defp debug_findings(function) do
    function
    |> IR.all_nodes()
    |> Enum.filter(&debug_call?/1)
    |> Enum.map(fn node ->
      Finding.new(
        kind: :my_app_debug_call,
        message: "Remove debug call before merging",
        location: location(node)
      )
    end)
  end

  defp debug_call?(%{type: :call, meta: %{module: IO, function: :inspect}}), do: true
  defp debug_call?(_node), do: false

  defp location(%{source_span: %{file: file, start_line: line}}), do: "#{file}:#{line}"
  defp location(_node), do: "unknown"
end
```

## Source DSL checks

For source-shape rules that are easy to express as patterns or per-node callbacks, use `Reach.Smell.Check.Source`. It supports ExAST patterns/selectors and AST callback rules through the same `smell` macro.

```elixir
defmodule MyApp.ReachSmells.NoBooleanCase do
  use Reach.Smell.Check.Source

  smell(
    :boolean_case,
    :my_app_boolean_case,
    "prefer if/else for boolean case expressions",
    mode: :ast,
    prefilter: {:all, ["case"]}
  )

  defp boolean_case({:case, meta, [subject, _clauses]}) do
    if match?({op, _, _} when op in [:==, :!=, :and, :or], subject), do: {:ok, meta}
  end

  defp boolean_case(_node), do: nil
end
```

Use source DSL checks when a rule is local to one AST node or can be expressed as an ExAST `~p` pattern. Set `remediation_safety: :equivalent` only when the recommended replacement preserves values, exceptions, and callback evaluation order across the rule's full matched domain. Use `:conditional` when the message states the required preconditions; otherwise keep the default `:review_only`. Use `Reach.Smell.Check.AST` when the check needs full-file state or a custom traversal.

## AST-backed source checks

For full-file source-shape rules, use `Reach.Smell.Check.AST`. It loads each source file once via Sourceror, reuses Reach's AST cache, and calls `scan_ast/2` with the file path.

```elixir
defmodule MyApp.ReachSmells.MissingTemplateResource do
  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:my_app_missing_template_resource]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{:template, _, [path]}]} = node, findings when is_binary(path) ->
          finding =
            Finding.new(
              kind: :my_app_missing_template_resource,
              message: "template module attribute should declare @external_resource",
              location: "#{file}:#{meta[:line] || 0}"
            )

          {node, [finding | findings]}

        node, findings ->
          {node, findings}
      end)

    Enum.reverse(findings)
  end
end
```

Prefer AST checks for syntax-sensitive rules such as DSL shape, module attributes, query macros, or literal interpolation. Prefer IR checks for semantic rules involving calls, effects, data flow, or nested function bodies.

## Baselines and strict mode

Custom smell findings use the same gating behavior as built-in smell findings.

Advisory mode:

```bash
mix reach.check --smells
```

Strict mode:

```bash
mix reach.check --smells --strict
```

Baseline existing findings:

```bash
mix reach.check --smells --write-baseline .reach-baseline.json
mix reach.check --smells --strict --baseline .reach-baseline.json
```

Or configure both in `.reach.exs`:

```elixir
[
  checks: [baseline: ".reach-baseline.json"],
  smells: [
    strict: true,
    custom_checks: [MyApp.ReachSmells.NoFoo]
  ]
]
```

With this setup, known findings in the baseline are suppressed and new findings fail CI.

## JSON output

Custom findings are included in JSON output:

```bash
mix reach.check --smells --format json
```

Example shape:

```json
{
  "command": "reach.check",
  "tool": "reach.check",
  "findings": [
    {
      "kind": "my_app_no_foo",
      "message": "Use MyApp.Bar instead of MyApp.Foo",
      "location": "lib/my_app/foo.ex:12",
      "confidence": "high"
    }
  ]
}
```

## Testing custom smells

Test custom checks directly with a small project fixture when possible. A minimal unit test can pass a hand-built project map:

```elixir
defmodule MyApp.ReachSmells.NoFooTest do
  use ExUnit.Case, async: true

  test "flags Foo calls" do
    project = %{
      nodes: %{
        1 => %Reach.IR.Node{
          id: 1,
          type: :call,
          meta: %{module: MyApp.Foo, function: :run},
          source_span: %{file: "lib/example.ex", start_line: 10},
          children: []
        }
      }
    }

    assert [%Reach.Smell.Finding{kind: :my_app_no_foo}] =
             MyApp.ReachSmells.NoFoo.run(project)
  end
end
```

For higher-confidence tests, parse a small source fixture with Reach and run the check against the resulting project.

## Framework-specific smells

Framework-specific smells belong in plugins rather than generic `Reach.Smell.*` modules. A plugin can expose smell modules with `smell_checks/0`:

```elixir
defmodule Reach.Plugins.MyFramework do
  @behaviour Reach.Plugin

  @impl true
  def smell_checks do
    [Reach.Plugins.MyFramework.Smells.NoLegacyAPI]
  end
end
```

Plugin smell checks still implement `Reach.Smell.Check`, run through the same registry as built-in and project-local checks, and participate in strict mode and baselines. This keeps framework policy near framework semantics such as effect classification, trace presets, and graph edges.

## Best practices

- Keep checks focused: one rule per module is easier to baseline and explain.
- Use precise locations. Avoid `"unknown"` unless the finding is truly project-level.
- Prefer stable messages and kinds so baselines do not churn unnecessarily.
- Avoid hardcoding generated paths unless the rule is specifically about generated code.
- Keep project-specific semantics in your application; contribute broadly useful semantics as Reach plugins or built-in checks.
