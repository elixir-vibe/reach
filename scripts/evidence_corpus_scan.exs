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
    {:ok, _apps} = Application.ensure_all_started(:ex_unit)
    plugins = Reach.Plugin.detect()
    providers = Reach.Evidence.ast_providers_for(kind_family(kind), plugins)

    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "{lib,test}/**/*.{ex,exs}")))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&scan_file(&1, providers, plugins))
    |> print_results(limit, format)
  end

  defp scan_file(path, providers, plugins) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- parse_source(source) do
      providers
      |> Enum.flat_map(&provider_evidence_silently(&1, ast, plugins))
      |> Enum.map(&Map.put(&1, :file, path))
    else
      _error -> []
    end
  end

  defp parse_source(source) do
    capture_stderr(fn ->
      {result, _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.string_to_quoted(source, emit_warnings: false)
        end)

      result
    end)
  end

  defp capture_stderr(fun) do
    parent = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(parent, {:captured_result, fun.()})
    end)

    receive do
      {:captured_result, result} -> result
    end
  end

  defp provider_evidence_silently(provider, ast, plugins) do
    {result, _diagnostics} =
      Code.with_diagnostics(fn -> provider_evidence(provider, ast, plugins) end)

    result
  end

  defp provider_evidence(Reach.Evidence.MapContract, ast, plugins) do
    ast
    |> Reach.Evidence.MapContract.collect_ast(plugins: plugins)
    |> Enum.map(fn contract ->
      message =
        "map #{inspect(contract.variable)} uses keys #{inspect(contract.keys)} as an implicit contract"

      Reach.Evidence.MapContract.family()
      |> evidence(:implicit_map_contract, message, contract.location, contract.confidence)
      |> Map.merge(%{
        variable: contract.variable,
        keys: contract.keys,
        source: contract.source,
        producer: contract.producer,
        role: contract.role,
        key_coverage: contract.key_coverage,
        observed_keys: contract.observed_keys,
        unused_keys: contract.unused_keys,
        read_count: contract.read_count,
        mutation_count: contract.mutation_count,
        escaped?: contract.escaped?,
        escapes: contract.escapes,
        consumer: contract.consumer
      })
    end)
  end

  defp provider_evidence(provider, ast, _plugins) do
    ast
    |> provider.collect_ast()
    |> Enum.map(&evidence(provider.family(), &1.kind, &1.message, &1.meta, &1.confidence))
  end

  defp kind_family("all"), do: :all
  defp kind_family("map-contract"), do: :map_contract
  defp kind_family(kind), do: String.to_existing_atom(kind)

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
