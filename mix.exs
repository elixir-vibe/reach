defmodule Reach.MixProject do
  use Mix.Project

  @version "2.8.1"
  @source_url "https://github.com/elixir-vibe/reach"

  def project do
    [
      app: :reach,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      elixirc_options: [
        no_warn_undefined: [
          {Makeup, :highlight_inner_html, 2},
          {Makeup, :stylesheet, 0}
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix, :eex, :ex_unit, :boxart, :program_facts],
        flags: [:no_opaque]
      ],
      name: "Reach",
      description:
        "Program dependence graph for Elixir, Erlang, Gleam, JavaScript, and TypeScript",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test, docs: :docs, "hex.publish": :docs]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "js.check",
        "credo --strict",
        "ex_dna",
        "reach.check --arch --smells",
        "dialyzer",
        "test",
        "calibration.ci"
      ],
      "assets.build": [
        "volt.build --name reach"
      ],
      "calibration.ci": &run_calibration_ci/1
    ]
  end

  defp run_calibration_ci(_args) do
    calibration_dir = Path.expand("dev/calibration", __DIR__)
    run_calibration_mix(["deps.get"], calibration_dir)
    run_calibration_mix(["ci"], calibration_dir)
  end

  defp run_calibration_mix(args, calibration_dir) do
    case System.cmd("mix", args, cd: calibration_dir, into: IO.stream()) do
      {_stream, 0} ->
        :ok

      {_stream, status} ->
        Mix.raise("Calibration command mix #{Enum.join(args, " ")} failed (#{status})")
    end
  end

  defp deps do
    [
      {:libgraph, "~> 0.16.0"},
      {:program_facts, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:boxart, "~> 0.3.3", optional: true},
      {:makeup, "~> 1.0", optional: true},
      {:makeup_elixir, "~> 1.0", optional: true},
      {:makeup_js, "~> 0.1", optional: true},
      {:volt, "~> 0.14", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :docs], runtime: false},
      {:quickbeam, "~> 0.10", optional: true},
      {:ex_ast, "~> 0.12.0"},
      {:ex_dna, "~> 1.5", optional: true, runtime: false}
    ]
  end

  defp docs do
    [
      main: "overview",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp extras do
    [
      "guides/overview.md",
      "guides/installation.md",
      "guides/quickstart.md",
      "guides/cli.md",
      "guides/json-output.md",
      "guides/configuration.md",
      "guides/concepts.md",
      "guides/custom-smells.md",
      "guides/validation.md",
      "guides/recipes.md",
      "guides/contributing.md",
      "docs/evidence-providers.md",
      "docs/evidence-heuristics.md",
      "CHANGELOG.md": [title: "Changelog"],
      LICENSE: [title: "License"]
    ]
  end

  defp groups_for_extras do
    [
      Introduction: ["guides/overview.md", "guides/installation.md", "guides/quickstart.md"],
      "Canonical CLI": ["guides/cli.md", "guides/json-output.md"],
      Configuration: ["guides/configuration.md", "guides/custom-smells.md"],
      Concepts: [
        "guides/concepts.md",
        "docs/evidence-providers.md",
        "docs/evidence-heuristics.md"
      ],
      Validation: ["guides/validation.md"],
      Recipes: ["guides/recipes.md"],
      Contributing: ["guides/contributing.md"]
    ]
  end

  defp groups_for_modules do
    [
      "Public API": [Reach, Reach.Project, Reach.MacroFact],
      "CLI Commands": [~r/Reach\.CLI\.Commands/],
      "CLI Rendering": [~r/Reach\.CLI\.Render/],
      "Project Queries": [Reach.Project.Query],
      Inspect: [~r/Reach\.Inspect/],
      Map: [~r/Reach\.Map/],
      Trace: [~r/Reach\.Trace/],
      Check: [~r/Reach\.Check/],
      Smells: [~r/Reach\.Smell/],
      OTP: [~r/Reach\.OTP/],
      Evidence: [~r/Reach\.Evidence/],
      IR: [Reach.IR, Reach.IR.Node, Reach.IR.Helpers],
      Analysis: [
        Reach.ControlFlow,
        Reach.DataDependence,
        Reach.ControlDependence,
        Reach.Dominator,
        Reach.Effects,
        Reach.SystemDependence
      ],
      Frontends: [~r/Reach\.Frontend/],
      Visualization: [~r/Reach\.Visualize/],
      Plugins: [Reach.Plugin, ~r/Reach\.Plugins/]
    ]
  end

  def build_assets(_) do
    {:ok, _result} =
      Volt.Builder.build(
        entry: "assets/js/app.ts",
        outdir: "priv/static",
        hash: false,
        name: "reach",
        sourcemap: false,
        code_splitting: false,
        define: %{"process.env.NODE_ENV" => ~s("production")},
        aliases: %{"@reach" => "assets/js"},
        node_modules: Path.expand("assets/node_modules")
      )
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv examples guides docs mix.exs README.md CONTRIBUTING.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
