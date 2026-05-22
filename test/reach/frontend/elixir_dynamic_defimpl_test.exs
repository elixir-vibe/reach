defmodule Reach.Frontend.ElixirDynamicDefimplTest do
  use ExUnit.Case, async: true

  test "does not crash on dynamic defimpl protocol names" do
    graph =
      Reach.string_to_graph!("""
      defmodule Example do
        defmacro derive_encoder(encoder) do
          quote do
            defimpl unquote(encoder), for: Ecto.Association.NotLoaded do
              def encode(value, opts), do: Jason.Encode.map(%{}, opts)
            end
          end
        end
      end
      """)

    assert is_list(Reach.nodes(graph))
  end
end
