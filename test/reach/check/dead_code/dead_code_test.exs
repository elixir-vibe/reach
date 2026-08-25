defmodule Reach.Check.DeadCodeTest do
  use ExUnit.Case, async: true

  alias Reach.Check.DeadCode

  test "ignores high-confidence macro DSL declarations" do
    path =
      temp_source(~S'''
      defmodule ReproComponent do
        use Phoenix.Component

        attr :id, :string, required: true
        slot :inner_block, required: true

        def card(assigns) do
          assigns
        end
      end

      defmodule ReproRouter do
        use Phoenix.Router

        pipeline :browser do
          plug :accepts, ["html"]
        end

        scope "/" do
          pipe_through :browser
          get "/health", HealthController, :show
        end
      end
      ''')

    findings = DeadCode.run([path], plugins: [Reach.Plugins.Phoenix])

    refute Enum.any?(findings, &String.contains?(&1.description, "attr result unused"))
    refute Enum.any?(findings, &String.contains?(&1.description, "slot result unused"))
    refute Enum.any?(findings, &String.contains?(&1.description, "pipeline result unused"))
    refute Enum.any?(findings, &String.contains?(&1.description, "scope result unused"))
    refute Enum.any?(findings, &String.contains?(&1.description, "get result unused"))
  end

  test "keeps ordinary unused pure calls" do
    path =
      temp_source(~S'''
      defmodule Repro do
        def run(value) do
          String.trim(value)
          value
        end
      end
      ''')

    assert Enum.any?(
             DeadCode.run([path]),
             &String.contains?(&1.description, "String.trim result unused")
           )
  end

  defp temp_source(source) do
    path = Path.join(System.tmp_dir!(), "reach-dead-code-#{System.unique_integer()}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
