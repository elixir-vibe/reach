defmodule Reach.Check.Changed.SourceSnapshot do
  @moduledoc false

  @spec revision(String.t(), keyword()) :: String.t()
  def revision(base, opts) do
    Keyword.get_lazy(opts, :old_revision, fn -> merge_base(base) end)
  end

  @spec source(:old | :new, Path.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def source(:old, file, revision, opts) do
    source_override(:old_sources, file, opts, fn -> git_source(revision, file) end)
  end

  def source(:new, file, _revision, opts) do
    source_override(:new_sources, file, opts, fn -> File.read(file) end)
  end

  defp source_override(key, file, opts, fallback) do
    if Keyword.has_key?(opts, key) do
      opts |> Keyword.fetch!(key) |> Map.fetch(file)
    else
      fallback.()
    end
  end

  defp merge_base(base) do
    case System.cmd("git", ["merge-base", base, "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      _error -> base
    end
  end

  defp git_source(nil, _file), do: {:error, :missing_revision}

  defp git_source(revision, file) do
    case System.cmd("git", ["show", "#{revision}:#{file}"], stderr_to_stdout: true) do
      {source, 0} -> {:ok, source}
      _error -> {:error, :missing_old_source}
    end
  end
end
