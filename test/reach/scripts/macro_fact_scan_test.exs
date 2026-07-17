defmodule Reach.Scripts.MacroFactScanTest do
  use ExUnit.Case, async: false

  test "macro fact scanner supports text and json output" do
    dir =
      Path.join(System.tmp_dir!(), "reach-macro-fact-scan-#{System.unique_integer([:positive])}")

    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "router.ex"), """
    defmodule MyAppWeb.Router do
      use Phoenix.Router
      get "/health", HealthController, :show
    end
    """)

    assert {text, 0} = scan(["--plugins", "Reach.Plugins.Phoenix", "--framework", "phoenix", dir])
    assert text =~ "Macro fact scan"
    assert text =~ "phoenix_router_use=1"
    assert text =~ "phoenix_route=1"

    assert {json, 0} =
             scan([
               "--plugins",
               "Reach.Plugins.Phoenix",
               "--framework",
               "phoenix",
               "--format",
               "json",
               dir
             ])

    assert [use_fact, route_fact] = JSON.decode!(json)
    assert use_fact["kind"] == "phoenix_router_use"
    assert route_fact["kind"] == "phoenix_route"

    File.rm_rf(dir)
  end

  defp scan(args) do
    System.cmd("mix", ["run", "--no-compile", "scripts/macro_fact_scan.exs", "--" | args],
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", Atom.to_string(Mix.env())},
        {"NO_COLOR", "1"},
        {"CLICOLOR", "0"},
        {"TERM", "dumb"}
      ]
    )
  end
end
