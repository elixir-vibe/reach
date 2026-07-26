defmodule Reach.Plugins.GettextTest do
  use ExUnit.Case, async: true

  alias Reach.IR.Node
  alias Reach.MacroFact
  alias Reach.Plugins.Gettext, as: Plugin

  describe "effect classification" do
    test "classifies locale setters as process-dictionary writes" do
      for {function, arity} <- [put_locale: 1, put_locale: 2, put_locale!: 2] do
        assert Plugin.classify_effect(call_node(function, arity)) == :write
      end
    end

    test "does not classify unrelated or invalid Gettext calls" do
      assert Plugin.classify_effect(call_node(:get_locale, 0)) == nil
      assert Plugin.classify_effect(call_node(:put_locale!, 1)) == nil
    end
  end

  test "refines use Gettext declarations into high-confidence macro facts" do
    source = """
    defmodule MyAppWeb.Gettext do
      use Gettext, backend: MyApp.Gettext
    end
    """

    assert {:ok,
            [
              %MacroFact{
                kind: :gettext_use,
                framework: :gettext,
                confidence: :high,
                owner_module: MyAppWeb.Gettext,
                target: Gettext
              }
            ]} = MacroFact.collect_source(source, plugins: [Plugin])
  end

  test "publishes dependency and source inference hints" do
    assert %{deps: [:gettext], source: source_hints} = Plugin.inference_hints()
    assert "Gettext" in source_hints
  end

  defp call_node(function, arity) do
    %Node{
      type: :call,
      id: 0,
      children: [],
      meta: %{kind: :remote, module: Gettext, function: function, arity: arity}
    }
  end
end
