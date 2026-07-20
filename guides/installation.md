# Installation

Add Reach to your project dependencies:

```elixir
{:reach, "~> 2.8", only: [:dev, :test], runtime: false}
```

Optional dependencies enable richer output:

```elixir
{:jason, "~> 1.0"},      # JSON output
{:boxart, "~> 0.3.3"},   # terminal graphs
{:makeup, "~> 1.0"},
{:makeup_elixir, "~> 1.0"},
{:makeup_js, "~> 0.1"}
```

Then fetch dependencies:

```bash
mix deps.get
```

For local development on Reach itself, run:

```bash
mix ci
```
