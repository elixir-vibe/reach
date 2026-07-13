defmodule Reach.Plugin.InferenceTest do
  use ExUnit.Case, async: true

  alias Reach.Plugin.Inference

  test "infers plugins from mix.exs dependencies without executing it" do
    dir = tmp_dir("mix")
    marker = Path.join(dir, "should-not-exist")

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      File.write!(#{inspect(marker)}, "executed")

      def project, do: [app: :demo, version: "0.1.0"]

      defp deps do
        [
          {:phoenix, "~> 1.8"},
          {:ecto_sql, "~> 3.13"},
          {:oban, "~> 2.19"},
          {:nx, "~> 0.10"}
        ]
      end
    end
    """)

    plugins = Inference.infer([dir])

    assert Reach.Plugins.Phoenix in plugins
    assert Reach.Plugins.Ecto in plugins
    assert Reach.Plugins.Oban in plugins
    assert Reach.Plugins.Nx in plugins
    refute File.exists?(marker)
  end

  test "infers plugins from source markers without mix.exs" do
    dir = tmp_dir("source")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/page_live.ex"), """
    defmodule DemoWeb.PageLive do
      use Phoenix.LiveView
    end
    """)

    plugins = Inference.infer([dir])

    assert Reach.Plugins.Phoenix in plugins
    assert Reach.Plugins.LiveView in plugins
  end

  test "explicit project plugins override inference" do
    dir = tmp_dir("override")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/schema.ex"), """
    defmodule Demo.Schema do
      use Ecto.Schema
    end
    """)

    project = Reach.Project.from_sources([Path.join(dir, "lib/schema.ex")], plugins: [])

    assert project.plugins == []
  end

  test "project source construction infers plugins when no override is provided" do
    dir = tmp_dir("project")
    path = Path.join(dir, "schema.ex")

    File.write!(path, """
    defmodule Demo.Schema do
      use Ecto.Schema
    end
    """)

    project = Reach.Project.from_sources([path])

    assert Reach.Plugins.Ecto in project.plugins
  end

  defp tmp_dir(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "reach-plugin-inference-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
