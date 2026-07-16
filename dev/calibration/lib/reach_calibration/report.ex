defmodule ReachCalibration.Report do
  @moduledoc false

  def write!(report, output) do
    output = Path.expand(output)
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(report))
    output
  end

  def print(report, output) do
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

    IO.puts("Wrote #{output}")
  end
end
