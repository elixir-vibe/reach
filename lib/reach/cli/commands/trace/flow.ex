defmodule Reach.CLI.Commands.Trace.Flow do
  @moduledoc """
  Traces data flow from sources to sinks. Detects taint paths where
  untrusted input reaches dangerous operations.

      mix reach.trace --from params --to write!
      mix reach.trace --variable user --in UserService.register/2
      mix reach.trace --from input --to System.cmd --format json
      mix reach.trace --pattern regex-on-structured

  ## Options

    * `--from` — taint source pattern (e.g. `params`, `input`)
    * `--to` — sink pattern (e.g. `write!`, `System.cmd`)
    * `--pattern` — run a named source-to-sink trace preset
    * `--variable` — trace a specific variable name
    * `--in` — restrict to a specific function
    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--limit` — text display limit; also caps taint paths unless `--all` is set
    * `--all` — show all text rows/paths and collect all taint paths

  """

  @switches [
    format: :string,
    from: :string,
    to: :string,
    pattern: :string,
    variable: :string,
    in: :string,
    limit: :integer,
    all: :boolean
  ]

  @aliases [f: :format]

  alias Reach.CLI.Options
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Trace.Flow, as: FlowRender
  alias Reach.Trace.Flow

  @default_path_limit 50
  @default_display_limit 30

  def run(args, cli_opts \\ []) do
    Options.run(args, @switches, @aliases, fn opts, _positional ->
      run_opts(opts, cli_opts)
    end)
  end

  def run_opts(opts, cli_opts \\ []) do
    format = opts[:format] || "text"

    project = opts[:project] || Project.load(quiet: format == "json")
    result = analyze(project, opts)

    FlowRender.render(result, format, display_limit(opts), command(cli_opts))
  end

  defp analyze(project, opts) do
    source = opts[:from]
    sink = opts[:to]

    cond do
      opts[:pattern] ->
        case Flow.analyze_preset(project, opts[:pattern], path_limit(opts)) do
          {:ok, result} ->
            result

          {:error, :unknown_preset} ->
            Mix.raise("Unknown trace pattern #{inspect(opts[:pattern])}")
        end

      source && sink ->
        Flow.analyze_taint(project, source, sink, path_limit(opts))

      opts[:variable] ->
        Flow.analyze_variable(project, opts[:variable], opts[:in])

      true ->
        Mix.raise("Provide --pattern, --from/--to, or --variable for data tracing")
    end
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.trace")

  defp path_limit(opts) do
    cond do
      opts[:all] -> :all
      is_integer(opts[:limit]) and opts[:limit] > @default_path_limit -> opts[:limit]
      true -> @default_path_limit
    end
  end

  defp display_limit(opts) do
    cond do
      opts[:all] -> :all
      is_integer(opts[:limit]) and opts[:limit] > 0 -> opts[:limit]
      true -> @default_display_limit
    end
  end
end
