defmodule Reach.Evidence.Provider do
  @moduledoc "Behaviour for source-AST evidence providers discovered by Reach and plugins."

  @callback family() :: atom()
  @callback kinds() :: [atom()]
  @callback collect_ast(Macro.t()) :: [map()]
end
