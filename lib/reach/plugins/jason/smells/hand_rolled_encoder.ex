defmodule Reach.Plugins.Jason.Smells.HandRolledEncoder do
  @moduledoc "Promotes calibrated hand-rolled JSON encoder evidence to smell findings."

  use Reach.Smell.Check.Evidence,
    provider: Reach.Plugins.Jason.Evidence.HandRolledEncoder
end
