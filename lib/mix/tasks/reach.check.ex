defmodule Mix.Tasks.Reach.Check do
  @moduledoc """
  Runs structural validation and change-safety checks.

      mix reach.check
      mix reach.check --arch
      mix reach.check --changed --base main
      mix reach.check --dead-code
      mix reach.check --smells
      mix reach.check --candidates

  ## Options

    * `--format` — output format: `text` or `json`
    * `--arch` — check `.reach.exs` architecture policy
    * `--changed` — report changed functions and configured test hints
    * `--base` — git base ref for `--changed` (default: auto-detect `main`, `master`, or upstream)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--strict` — fail when smell findings are present (or set `smells: [strict: true]`)
    * `--baseline` — ignore known findings from a Reach baseline file
    * `--write-baseline` — write current findings to a Reach baseline file
    * `--candidates` — emit advisory refactoring candidates
    * `--top` — limit candidate output for `--candidates`
    * `--path` — analyze an explicit source path instead of environment-derived Mix paths

  """

  use Mix.Task

  alias Reach.CLI.Commands.Check
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Structural validation and change-safety checks"

  @switches [
    format: :string,
    arch: :boolean,
    changed: :boolean,
    base: :string,
    dead_code: :boolean,
    smells: :boolean,
    strict: :boolean,
    baseline: :string,
    write_baseline: :string,
    candidates: :boolean,
    path: :string,
    top: :integer
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, positional} = Options.parse(args, @switches, @aliases)
      Check.run(opts, positional)
    end)
  end
end
