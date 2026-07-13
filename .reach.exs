mix_task_run = ["Mix.Task.run/1", "Mix.Task.run/2"]
cli_calls = ["Reach.CLI.*" | mix_task_run]
cli_render_calls = ["Reach.CLI.Render.*" | mix_task_run]

forbid_cli_or_mix = fn modules ->
  Enum.map(modules, &{&1, cli_calls})
end

layers = [
  cli: ["Mix.Tasks.*", "Reach.CLI.*"],
  plugin: ["Reach.Plugin", "Reach.Plugin.*", "Reach.Plugins.*"],
  evidence: ["Reach.Evidence", "Reach.Evidence.*"],
  smell: ["Reach.Smell.*"],
  check: ["Reach.Check.*"],
  frontend: ["Reach.Frontend", "Reach.Frontend.*", "Reach.Source", "Reach.Source.*"],
  visualize: ["Reach.Visualize", "Reach.Visualize.*"],
  inspect: ["Reach.Inspect.*"],
  project: ["Reach.Project", "Reach.Project.*"],
  config: ["Reach.Config", "Reach.Config.*"],
  core: [
    "Reach",
    "Reach.Analysis",
    "Reach.AST",
    "Reach.CallGraph",
    "Reach.Concurrency",
    "Reach.ControlDependence",
    "Reach.ControlFlow",
    "Reach.DataDependence",
    "Reach.DependencySummary",
    "Reach.Dominator",
    "Reach.Effects",
    "Reach.ErlangFrontend",
    "Reach.Graph",
    "Reach.GraphAlgorithms",
    "Reach.HigherOrder",
    "Reach.IR",
    "Reach.IR.*",
    "Reach.MacroFact",
    "Reach.Map.*",
    "Reach.OTP",
    "Reach.OTP.*",
    "Reach.SystemDependence",
    "Reach.Trace.*"
  ]
]

removed_modules = [
  "Reach.CLI.Analyses.*",
  "Reach.CLI.TaskRunner",
  "Reach.CloneAnalysis.*",
  "Reach.Plugins.JSON"
]

removed_files = [
  "lib/reach/cli/analyses/**",
  "lib/reach/cli/task_runner.ex",
  "lib/reach/clone_analysis/**",
  "lib/reach/plugins/json.ex"
]

[
  layers: layers,
  deps: [
    forbidden: [
      {:core, :cli},
      {:frontend, :cli},
      {:project, :cli},
      {:visualize, :cli},
      {:evidence, :cli},
      {:smell, :cli},
      {:check, :cli}
    ]
  ],
  calls: [
    forbidden:
      forbid_cli_or_mix.(
        ~w(Reach.Evidence.* Reach.Smell.* Reach.Frontend.* Reach.Plugin Reach.Plugins.*)
      ) ++
        [
          {"Reach.Check.*", cli_render_calls},
          {"Reach.Project*", ["Reach.CLI.Render.*"]},
          {"Reach.Visualize.*", ["Reach.CLI.Commands.*" | mix_task_run]},
          {"Reach.CLI.Render.Check*", ["Reach.CLI.Format.header", "Reach.CLI.Format.section"]}
        ]
  ],
  source: [
    forbidden_modules: removed_modules,
    forbidden_files: removed_files
  ],
  checks: [
    baseline: ".reach-baseline.json",
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: [
        "Reach.MixProject",
        "Reach.Test.*",
        "Reach.CLI.JSONEnvelope",
        "Jason.Encoder.*",
        "JSON.Encoder.*"
      ]
    ]
  ],
  clone_analysis: [
    max_clones: 20
  ],
  smells: [
    strict: true,
    fixed_shape_map: [min_occurrences: 20],
    behaviour_candidate: [min_modules: 4]
  ]
]
