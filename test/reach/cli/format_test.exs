defmodule Reach.CLI.FormatTest do
  use ExUnit.Case, async: true

  alias Reach.CLI.Format
  alias Reach.CLI.JSON, as: CLIJSON
  alias Reach.Map.EffectCall

  test "location_text formats map locations" do
    assert Format.location_text(%{file: "lib/demo.ex", line: 12}) =~ "lib/demo.ex:12"
    assert Format.location_text(%{file: "lib/demo.ex", line: 12, column: 4}) =~ "lib/demo.ex:12"
    assert Format.location_text(%{file: "lib/demo.ex", start_line: 7}) =~ "lib/demo.ex:7"
  end

  test "effect formatting accepts the complete effect atom contract" do
    effects = [:pure, :read, :write, :io, :send, :receive, :exception, :nif, :unknown]

    Enum.each(effects, fn effect ->
      assert Format.effect(effect) =~ Atom.to_string(effect)
    end)
  end

  test "JSON conversion stringifies typed effect atoms at the boundary" do
    data = CLIJSON.to_data(%EffectCall{effect: :write, call: "Repo.update/1"})

    assert data == %{"effect" => "write", "call" => "Repo.update/1"}
  end
end
