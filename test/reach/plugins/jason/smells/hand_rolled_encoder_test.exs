defmodule Reach.Plugins.Jason.Smells.HandRolledEncoderTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Plugins.Jason
  alias Reach.Plugins.Jason.Smells.HandRolledEncoder

  test "Jason plugin contributes the hand-rolled encoder smell" do
    assert HandRolledEncoder in Reach.Plugin.smell_checks([Jason])
  end

  test "detects hand-rolled JSON sanitizers only when the Jason plugin is enabled" do
    path = Path.join(System.tmp_dir!(), "jason_smell_#{System.unique_integer([:positive])}.ex")

    File.write!(path, """
    defmodule Example do
      def json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()
      def json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
      def json_safe(value), do: value
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [Jason])

    assert [%{kind: :hand_rolled_json_sanitizer}] = Smells.run(project, [])

    project_without_plugins = Reach.Project.from_sources([path], plugins: [])
    assert [] = Smells.run(project_without_plugins, [])

    File.rm(path)
  end
end
