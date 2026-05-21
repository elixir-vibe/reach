defmodule Reach.Plugins.LiveView.HEEx.Node do
  @moduledoc false

  defmodule Template do
    @moduledoc false
    defstruct [:children, :span]
  end

  defmodule Text do
    @moduledoc false
    defstruct [:text, :span]
  end

  defmodule Expr do
    @moduledoc false
    defstruct [:marker, :code, :ast, :span]
  end

  defmodule EExBlock do
    @moduledoc false
    defstruct [:marker, :head_code, :head_ast, :clauses, :span]
  end

  defmodule EExClause do
    @moduledoc false
    defstruct [:code, :ast, :children, :span]
  end

  defmodule Tag do
    @moduledoc false
    defstruct [:type, :name, :attrs, :special, :children, :open_span, :close_span, :span]
  end

  defmodule Attr do
    @moduledoc false
    defstruct [:name, :value, :span]
  end

  defmodule SpecialAttr do
    @moduledoc false
    defstruct [:name, :code, :ast, :span]
  end
end
