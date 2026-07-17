defmodule Reach.Source.SuppressionTest do
  use ExUnit.Case, async: true

  alias Reach.Source.Suppression

  test "parses suppression scopes, tokens, targets, and reasons" do
    source = """
    # reach:disable-for-this-file default_drift, dual_key_access -- legacy payload contract
    defmodule Sample do
      # reach:disable-next-line pipeline_waste -- generated compatibility path
      def run(value), do: value
    end
    """

    assert [file, next_line] = Suppression.parse_source(source, "lib/sample.ex")

    assert file.scope == :file
    assert file.tokens == ["default_drift", "dual_key_access"]
    assert file.reason == "legacy payload contract"
    assert is_nil(file.target_line)

    assert next_line.scope == :next_line
    assert next_line.tokens == ["pipeline_waste"]
    assert next_line.reason == "generated compatibility path"
    assert next_line.target_line == 4
  end

  test "supports the concise disable alias for the next line" do
    source = """
    # reach:disable default_drift -- compatibility boundary
    def run(value), do: value
    """

    assert [%{scope: :next_line, target_line: 2, reason: "compatibility boundary"}] =
             Suppression.parse_source(source, "sample.ex")
  end

  test "marks missing and empty reasons as reasonless" do
    source = """
    # reach:disable-next-line default_drift
    # reach:disable-next-line dual_key_access --
    """

    assert Enum.all?(Suppression.parse_source(source, "sample.ex"), &is_nil(&1.reason))
  end

  test "ignores lookalikes inside strings and heredocs" do
    source = ~S'''
    value = "# reach:disable-next-line all"

    heredoc = """
    # reach:disable-for-this-file all
    """
    '''

    assert [] = Suppression.parse_source(source, "sample.ex")
  end
end
