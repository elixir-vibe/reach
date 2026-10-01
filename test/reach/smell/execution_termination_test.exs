defmodule Reach.Smell.ExecutionTerminationTest do
  use ExUnit.Case, async: true

  alias Reach.Smell.Checks.RedundantComputation

  defp check(code) do
    path =
      Path.join(System.tmp_dir!(), "reach_termination_#{:erlang.unique_integer([:positive])}.ex")

    File.write!(path, code)
    on_exit(fn -> File.rm!(path) end)
    project = Reach.Project.from_sources([path])
    Reach.Effects.infer_local_effects(project.nodes)
    RedundantComputation.run(project)
  end

  test "ordered raising validations cannot execute both diagnostic conversions" do
    assert [] ==
             check("""
             defmodule OrderedRaisingValidation do
               def validate(items, positive, whole) do
                 unless positive do
                   raise "must be positive: \#{length(items)}"
                 end
                 unless whole do
                   raise "must be whole: \#{length(items)}"
                 end
                 :ok
               end
             end
             """)
  end

  test "a terminal case arm in an assignment cannot reach a later diagnostic arm" do
    assert [] ==
             check("""
             defmodule AssignedRaisingCase do
               def validate(items, first, second) do
                 selected =
                   case first do
                     :invalid -> raise "first: \#{length(items)}"
                     value -> value
                   end
                 case second do
                   :invalid -> raise "second: \#{length(items)}"
                   _ -> selected
                 end
               end
             end
             """)
  end

  test "same-source unconditional raising helpers have proved terminal contracts" do
    assert [] ==
             check("""
             defmodule SourceRaisingHelper do
               def validate(items, first, second) do
                 if first do
                   fail!("first: \#{length(items)}")
                 end
                 if second do
                   fail!("second: \#{length(items)}")
                 end
                 :ok
               end
               defp fail!(message), do: raise(ArgumentError, message: message)
             end
             """)
  end

  test "opaque and bang-named calls are not assumed terminal" do
    assert [_finding] =
             check("""
             defmodule ReturningBangHelper do
               def validate(items, first, second) do
                 if first do
                   check!("first: \#{length(items)}")
                 end
                 if second do
                   check!("second: \#{length(items)}")
                 end
                 :ok
               end
               defp check!(_message), do: :ok
             end
             """)
  end

  test "calls before and after a conditional raise can execute on the same path" do
    assert [_finding] =
             check("""
             defmodule SuccessfulValidationCalls do
               def validate(items, invalid) do
                 first = length(items)
                 if invalid, do: raise("invalid")
                 second = length(items)
                 {first, second}
               end
             end
             """)
  end

  test "a diagnostic call can repeat an earlier call before raising" do
    assert [_finding] =
             check("""
             defmodule EarlierDiagnosticCall do
               def validate(items, invalid) do
                 first = length(items)
                 if invalid, do: raise("invalid: \#{length(items)}")
                 first
               end
             end
             """)
  end

  test "duplicates within one raising message both execute before termination" do
    assert [_finding] =
             check("""
             defmodule RepeatedRaisingMessage do
               def validate(items) do
                 raise(
                   "first: \#{length(items)}" <>
                     "second: \#{length(items)}"
                 )
               end
             end
             """)
  end

  test "opposite requirements on the same immutable gate cannot execute together" do
    assert [] ==
             check("""
             defmodule StableBooleanAlternatives do
               def validate(items, gate) do
                 paired = gate and length(items) > 0
                 cond do
                   paired -> :paired
                   gate -> :gated
                   length(items) > 0 -> :late
                   true -> :empty
                 end
               end
             end
             """)
  end

  test "rebinding a gate does not equate the old and new truthiness constraints" do
    assert [_finding] =
             check("""
             defmodule ReboundBooleanGate do
               def validate(items, gate) do
                 paired = gate and length(items) > 0
                 gate = false
                 cond do
                   paired -> :paired
                   gate -> :gated
                   length(items) > 0 -> :late
                   true -> :empty
                 end
               end
             end
             """)
  end

  test "same-gate shortcircuit calls remain redundant when both can execute" do
    assert [_finding] =
             check("""
             defmodule SameBooleanGate do
               def validate(items, gate) do
                 first = gate and length(items) > 0
                 second = gate and length(items) > 0
                 {first, second}
               end
             end
             """)
  end

  test "opaque predicate invocations do not acquire stable binding equivalence" do
    assert [_finding] =
             check("""
             defmodule OpaqueBooleanGate do
               def validate(items, gate) do
                 first = gate.() and length(items) > 0
                 cond do
                   gate.() -> first
                   length(items) > 0 -> :late
                   true -> :empty
                 end
               end
             end
             """)
  end
end
