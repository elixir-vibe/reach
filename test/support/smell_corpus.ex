defmodule Reach.Test.SmellCorpus do
  @moduledoc false

  alias Reach.Check.Smells
  alias Reach.Project
  alias Reach.Smell.Suppressions

  @type package :: %{
          name: String.t(),
          version: String.t(),
          sha256: String.t(),
          plugins: [module()]
        }

  @packages [
    %{
      name: "jason",
      version: "1.4.5",
      sha256: "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684",
      plugins: [Reach.Plugins.Jason]
    },
    %{
      name: "plug",
      version: "1.20.3",
      sha256: "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76",
      plugins: []
    },
    %{
      name: "ecto",
      version: "3.14.1",
      sha256: "24b991956796700f467d0a3ef3d303138a3ef9ddddf8b98f43758ee067b20a30",
      plugins: [Reach.Plugins.Ecto]
    },
    %{
      name: "phoenix",
      version: "1.8.9",
      sha256: "3477e2dd5a4f61820341169031bdfe21275f659923bea9c5c0ea2aa1c3fcc046",
      plugins: [Reach.Plugins.Phoenix]
    },
    %{
      name: "decimal",
      version: "3.1.1",
      sha256: "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6",
      plugins: []
    },
    %{
      name: "gettext",
      version: "1.0.2",
      sha256: "eab805501886802071ad290714515c8c4a17196ea76e5afc9d06ca85fb1bfeb3",
      plugins: []
    },
    %{
      name: "floki",
      version: "0.38.4",
      sha256: "bdb34645eee8e79845c7edaca2d4099a52804ee4d4a3ecc683a69451f0244973",
      plugins: []
    },
    %{
      name: "credo",
      version: "1.7.19",
      sha256: "2d8bc95d5a7bb99dd2613621d4f08c6a3575c3fd4b62e6a2b48a100352a557b8",
      plugins: []
    }
  ]

  @snapshot_dir Path.expand("../fixtures/smell_corpus", __DIR__)
  @local_hex_mirror "/srv/toys/hex-mirror/tarballs"

  @spec packages() :: [package()]
  def packages, do: @packages

  @spec identities(package()) :: [String.t()]
  def identities(package) do
    root = fetch(package)
    paths = root |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.sort()
    project = Project.from_sources(paths, plugins: package.plugins)

    project
    |> Smells.run(clone_analysis: [provider: false])
    |> Enum.map(&identity(&1, root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec snapshot(package()) :: [String.t()]
  def snapshot(package) do
    package
    |> snapshot_path()
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  @spec write_snapshot(package(), [String.t()]) :: :ok
  def write_snapshot(package, identities) do
    path = snapshot_path(package)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(identities, &[&1, "\n"]))
  end

  @spec snapshot_path(package()) :: Path.t()
  def snapshot_path(package), do: Path.join(@snapshot_dir, package.name <> ".txt")

  @spec fetch(package()) :: Path.t()
  def fetch(package) do
    tarball = tarball(package)
    verify_checksum!(tarball, package)

    root =
      Path.join(
        cache_root(),
        "#{package.name}-#{package.version}-#{String.slice(package.sha256, 0, 12)}"
      )

    if package_ready?(root) do
      root
    else
      extract!(tarball, root)
    end
  end

  @spec cache_root() :: Path.t()
  def cache_root do
    System.get_env("REACH_SMELL_CORPUS_CACHE") ||
      Path.join(:filename.basedir(:user_cache, "reach"), "smell-corpus")
  end

  defp tarball(package) do
    filename = "#{package.name}-#{package.version}.tar"

    [
      System.get_env("REACH_HEX_TARBALL_DIR"),
      System.get_env("EXOGRAPH_TARBALL_DIR"),
      @local_hex_mirror,
      Path.join(Mix.Utils.mix_home(), "packages/hexpm"),
      Path.join(cache_root(), "tarballs")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join(&1, filename))
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> download_tarball!(package, filename)
      path -> path
    end
  end

  defp download_tarball!(package, filename) do
    destination = Path.join([cache_root(), "tarballs", filename])
    output_dir = Path.dirname(destination)
    File.mkdir_p!(output_dir)
    File.rm_rf!(destination)

    {output, status} =
      System.cmd(
        "mix",
        ["hex.package", "fetch", package.name, package.version, "--output", output_dir],
        cd: cache_root(),
        stderr_to_stdout: true
      )

    if status != 0 or not File.regular?(destination) do
      File.rm_rf!(destination)
      raise "could not fetch #{package.name} #{package.version}:\n#{output}"
    end

    destination
  end

  defp verify_checksum!(tarball, package) do
    actual =
      tarball |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    if actual != package.sha256 do
      raise "checksum mismatch for #{package.name} #{package.version}: expected #{package.sha256}, got #{actual}"
    end
  end

  defp extract!(tarball, root) do
    File.mkdir_p!(Path.dirname(root))
    File.rm_rf!(root)

    staging = root <> ".tmp-#{System.unique_integer([:positive])}"
    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    try do
      {:ok, outer_files} = :erl_tar.extract(String.to_charlist(tarball), [:memory])
      {_, contents} = List.keyfind(outer_files, ~c"contents.tar.gz", 0)
      {:ok, package_files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])

      package_files
      |> Enum.filter(fn {path, _contents} ->
        path = to_string(path)
        String.starts_with?(path, "lib/") and Path.extname(path) == ".ex"
      end)
      |> Enum.each(fn {path, contents} ->
        destination = safe_destination!(staging, to_string(path))
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, contents)
      end)

      File.write!(Path.join(staging, ".complete"), "")
      File.rename!(staging, root)
      root
    after
      File.rm_rf!(staging)
    end
  end

  defp safe_destination!(root, relative_path) do
    destination = Path.expand(relative_path, root)

    if String.starts_with?(destination, root <> "/") do
      destination
    else
      raise "unsafe path in Hex tarball: #{inspect(relative_path)}"
    end
  end

  defp package_ready?(root) do
    File.regular?(Path.join(root, ".complete")) and File.dir?(Path.join(root, "lib"))
  end

  defp identity(finding, root) do
    {file, line} = Suppressions.location(finding)
    path = if file, do: Path.relative_to(file, root), else: "unknown"
    "#{path}:#{line || 0}  #{finding.kind}"
  end
end
