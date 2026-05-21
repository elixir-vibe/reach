defmodule Reach.EvidenceCorpusScan do
  @moduledoc false

  @kinds ~w(jason stdlib map-contract all)

  def run(["--" | argv]), do: run(argv)

  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [kind: :string, limit: :integer, format: :string],
        aliases: [k: :kind, n: :limit, f: :format]
      )

    if invalid != [], do: usage("invalid option(s): #{inspect(invalid)}")

    kind = Keyword.get(opts, :kind, "all")
    limit = Keyword.get(opts, :limit, 20)
    format = Keyword.get(opts, :format, "text")

    unless kind in @kinds, do: usage("unknown kind #{inspect(kind)}")
    unless format in ["text", "json"], do: usage("unknown format #{inspect(format)}")

    case args do
      [] -> usage("expected at least one repository or source directory")
      paths -> scan(paths, kind, limit, format)
    end
  end

  defp scan(paths, kind, limit, format) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "{lib,test}/**/*.{ex,exs}")))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&scan_file(&1, kind))
    |> print_results(limit, format)
  end

  defp scan_file(path, kind) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      evidence_for(ast, kind)
      |> Enum.map(&Map.put(&1, :file, path))
    else
      _error -> []
    end
  end

  defp evidence_for(ast, "all") do
    evidence_for(ast, "jason") ++ evidence_for(ast, "stdlib") ++ evidence_for(ast, "map-contract")
  end

  defp evidence_for(ast, "jason") do
    ast
    |> Reach.Plugins.Jason.Evidence.HandRolledEncoder.collect_ast()
    |> Enum.map(&evidence(:jason, &1.kind, &1.message, &1.meta, &1.confidence))
  end

  defp evidence_for(ast, "stdlib") do
    ast
    |> Reach.Evidence.StandardLibraryBypass.collect_ast()
    |> Enum.map(&evidence(:stdlib, &1.kind, &1.message, &1.meta, &1.confidence))
  end

  defp evidence_for(ast, "map-contract") do
    ast
    |> Reach.Evidence.MapContract.collect_ast()
    |> Enum.map(fn contract ->
      message =
        "map #{inspect(contract.variable)} uses keys #{inspect(contract.keys)} as an implicit contract"

      :map_contract
      |> evidence(:implicit_map_contract, message, contract.location, contract.confidence)
      |> Map.merge(%{
        variable: contract.variable,
        keys: contract.keys,
        source: contract.source,
        producer: contract.producer
      })
    end)
  end

  defp print_results(results, _limit, "json") do
    results
    |> Enum.map(&json_result/1)
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  defp print_results(results, limit, "text") do
    grouped = Enum.group_by(results, & &1.family)

    IO.puts("Evidence corpus scan")
    IO.puts("total=#{length(results)}")

    for {family, family_results} <- Enum.sort_by(grouped, fn {family, _} -> family end) do
      IO.puts("\n## #{family} #{length(family_results)}")

      family_results
      |> Enum.frequencies_by(& &1.kind)
      |> Enum.sort_by(fn {kind, count} -> {-count, kind} end)
      |> Enum.each(fn {kind, count} -> IO.puts("#{kind}=#{count}") end)

      family_results
      |> Enum.take(limit)
      |> Enum.each(fn result ->
        IO.puts("- #{result.kind} #{result.file}:#{result.line} #{result.message}")
      end)
    end
  end

  defp json_result(result) do
    Map.new(result, fn {key, value} -> {to_string(key), json_value(value)} end)
  end

  defp json_value(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  defp json_value(value), do: value

  defp evidence(family, kind, message, meta, confidence) do
    %{family: family, kind: kind, message: message, line: meta[:line], confidence: confidence}
  end

  defp usage(message) do
    Mix.raise("""
    #{message}

    Usage:
      mix run scripts/evidence_corpus_scan.exs -- --kind jason PATH [PATH...]
      mix run scripts/evidence_corpus_scan.exs -- --kind stdlib PATH [PATH...]
      mix run scripts/evidence_corpus_scan.exs -- --kind map-contract PATH [PATH...]
      mix run scripts/evidence_corpus_scan.exs -- --kind all --format json PATH [PATH...]

    Kinds: #{Enum.join(@kinds, ", ")}
    """)
  end
end

Reach.EvidenceCorpusScan.run(System.argv())
