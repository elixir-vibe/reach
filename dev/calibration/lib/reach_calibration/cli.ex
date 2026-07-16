defmodule ReachCalibration.CLI do
  @moduledoc false

  alias ReachCalibration.{Candidates, Config}

  @switches [
    base_url: :string,
    limit: :integer,
    output: :string,
    labels: :string,
    paths: :keep,
    kinds: :string,
    candidate_limit: :integer,
    seed: :string,
    help: :boolean
  ]
  @aliases [u: :base_url, l: :limit, o: :output, h: :help]

  def parse!(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if invalid != [] or positional != [] do
      raise ArgumentError, usage_error(invalid, positional)
    end

    parsed
    |> Keyword.delete(:paths)
    |> Keyword.put(:paths, Keyword.get_values(parsed, :paths))
    |> Keyword.update(:kinds, [], &parse_kinds!/1)
    |> Config.new!()
  end

  def usage do
    """
    Usage:
      mix calibration.run [options]

    Options:
      --base-url, -u URL       Exograph API base URL. Defaults to http://localhost:4200.
      --limit, -l N            Maximum package versions selected. Defaults to 25.
      --output, -o PATH        Report path. Defaults to ./exograph-calibration-results.json.
      --labels PATH            JSON object mapping finding IDs to review verdicts.
      --paths GLOB             Hydrated path glob. May be repeated.
      --kinds a,b,c            Restrict analysis and metrics to smell kinds.
      --candidate-limit N      Maximum indexed candidates fetched before selection.
      --seed VALUE             Stable selection seed. Defaults to reach-calibration-v1.
      --help, -h               Show this help.
    """
  end

  defp parse_kinds!(value) do
    supported = Map.new(Candidates.supported_kinds(), &{Atom.to_string(&1), &1})

    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn kind ->
      Map.get(supported, kind) || raise ArgumentError, "unsupported smell kind #{inspect(kind)}"
    end)
  end

  defp usage_error(invalid, positional) do
    "invalid calibration arguments: #{inspect(invalid ++ positional)}\n\n#{usage()}"
  end
end
