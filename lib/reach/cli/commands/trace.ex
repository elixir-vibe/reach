defmodule Reach.CLI.Commands.Trace do
  @moduledoc """
  Traces data flow, taint paths, and forward/backward slices.

      mix reach.trace --from params --to write!
      mix reach.trace --from input --to System.cmd
      mix reach.trace --pattern regex-on-structured
      mix reach.trace --variable user --in MyApp.Accounts.create/1
      mix reach.trace --backward lib/my_app/accounts.ex:45
      mix reach.trace --forward lib/my_app/accounts.ex:45

  ## Options

    * `--from` — taint source pattern
    * `--to` — sink pattern
    * `--pattern` — run a named source-to-sink trace preset
    * `--variable` — trace a variable name
    * `--in` — restrict variable tracing to a function
    * `--backward` — compute a backward slice from a target
    * `--forward` — compute a forward slice from a target
    * `--format` — output format: `text`, `json`, `oneline`
    * `--graph` — render slice graph where supported
    * `--limit` — text display limit for paths/rows; also caps taint paths unless `--all` is set
    * `--all` — show all text rows/paths and collect all taint paths

  """

  alias Reach.CLI.Commands.Trace.{Flow, Slice}

  def run(opts, positional \\ []) do
    case trace_action(opts, positional) do
      :flow ->
        Flow.run_opts(opts, command: "reach.trace")

      {:slice, target, direction} ->
        opts = Keyword.put(opts, :forward, Keyword.fetch!(direction, :forward?))
        Slice.run_target(target, opts, command: "reach.trace")

      :error ->
        Mix.raise(
          "Provide --pattern, --from/--to, --variable, --backward TARGET, or --forward TARGET"
        )
    end
  end

  defp trace_action(opts, positional) do
    [
      {flow_trace?(opts, positional), :flow},
      {opts[:backward], {:slice, opts[:backward], forward?: false}},
      {opts[:forward], {:slice, opts[:forward], forward?: true}},
      {positional != [], {:slice, List.first(positional), forward?: false}}
    ]
    |> Enum.find_value(:error, fn
      {nil, _action} -> nil
      {false, _action} -> nil
      {_enabled, action} -> action
    end)
  end

  defp flow_trace?(opts, positional) do
    not slice_mode?(opts) and
      (opts[:pattern] || opts[:from] || opts[:to] || (opts[:variable] && opts[:in]) ||
         (opts[:variable] && positional == []))
  end

  defp slice_mode?(opts), do: opts[:backward] != nil or opts[:forward] != nil
end
