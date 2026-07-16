defmodule Reach.Scripts.ExographCorpusScan do
  @moduledoc false

  alias Reach.Calibration.Runner

  def main(["--" | argv]), do: main(argv)

  def main(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          base_url: :string,
          limit: :integer,
          output: :string,
          labels: :string,
          paths: :keep,
          kinds: :string,
          help: :boolean
        ],
        aliases: [u: :base_url, l: :limit, o: :output, h: :help]
      )

    if Keyword.get(opts, :help, false) or invalid != [] do
      usage(invalid)
    end

    output = opts[:output] || Path.join(File.cwd!(), "exograph-calibration-results.json")

    runner_opts =
      [
        base_url: opts[:base_url] || "http://localhost:4200",
        limit: opts[:limit] || 25,
        kinds: kinds(opts[:kinds]),
        labels: opts[:labels]
      ]
      |> put_paths(Keyword.get_values(opts, :paths))

    case Runner.run(runner_opts) do
      {:ok, report} ->
        File.mkdir_p!(Path.dirname(Path.expand(output)))
        File.write!(output, JSON.encode!(report))
        print_summary(report, output)

      {:error, reason} ->
        Mix.raise("Exograph calibration failed: #{inspect(reason)}")
    end
  end

  defp put_paths(opts, []), do: opts
  defp put_paths(opts, paths), do: Keyword.put(opts, :paths, paths)

  defp kinds(nil), do: nil

  defp kinds(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
    |> MapSet.new()
  rescue
    ArgumentError -> Mix.raise("--kinds contains an unknown smell kind")
  end

  defp print_summary(report, output) do
    summary = report["summary"]

    IO.puts(
      "packages=#{summary["packages"]} errors=#{summary["errors"]} findings=#{summary["findings"]}"
    )

    summary["by_kind"]
    |> Enum.sort_by(fn {kind, _metrics} -> kind end)
    |> Enum.each(fn {kind, metrics} ->
      precision = metrics["precision"] || "unreviewed"

      IO.puts(
        "#{kind}: total=#{metrics["total"]} reviewed=#{metrics["reviewed"]} precision=#{precision}"
      )
    end)

    IO.puts("Wrote #{Path.expand(output)}")
  end

  defp usage(invalid) do
    if invalid != [], do: IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")

    IO.puts("""
    Usage:
      mix run scripts/exograph_corpus_scan.exs -- [options]

    Options:
      --base-url, -u URL     Exograph API base URL. Defaults to http://localhost:4200.
      --limit, -l N          Maximum package versions selected. Defaults to 25.
      --output, -o PATH      Report path. Defaults to ./exograph-calibration-results.json.
      --labels PATH          JSON object mapping finding IDs to true_positive or false_positive.
      --paths GLOB           Hydrated path glob. May be repeated. Defaults to indexed candidate files.
      --kinds a,b,c          Restrict analysis and precision metrics to smell kinds.
      --help, -h             Show this help.
    """)

    if invalid == [], do: System.halt(0), else: System.halt(2)
  end
end

Reach.Scripts.ExographCorpusScan.main(System.argv())
