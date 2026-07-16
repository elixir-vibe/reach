defmodule Reach.Trace.Pattern.Preset do
  @moduledoc "A named set of source-to-sink matcher routes for trace analysis."

  alias Reach.IR.Node

  @type matcher :: (Node.t() -> boolean())
  @type route :: %{source: matcher(), sink: matcher()}
  @type t :: %__MODULE__{
          name: String.t(),
          from: String.t(),
          to: String.t(),
          routes: [route()]
        }

  @enforce_keys [:name, :from, :to, :routes]
  defstruct [:name, :from, :to, :routes]
end
