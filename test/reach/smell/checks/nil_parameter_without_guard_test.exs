defmodule Reach.Smell.Checks.NilParameterWithoutGuardTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "reports nil-capable parameters at the unguarded use" do
    findings =
      smells("""
      defmodule UnguardedToken do
        def caller, do: handle(nil)
        def handle(token), do: token.name
      end
      """)

    assert [finding] = by_kind(findings)
    assert finding.confidence == :high
    assert finding.location =~ ":3"
    assert finding.message =~ "UnguardedToken.handle/1 parameter token"
    assert finding.evidence =~ "call site"
    assert finding.evidence =~ "clause head"
  end

  test "reports both historical response-handler strict-callee shapes" do
    findings =
      smells("""
      defmodule ResponseHandlerShape do
        def caller(response, body) do
          handle_response(nil, response)
          handle_response(nil, 429, body)
        end

        def handle_response(token, %{status: status}) do
          if status == 429, do: TokenPoolShape.mark_rate_limited(token, 1_000)
        end

        def handle_response(token, status, _body) do
          if status == 429, do: TokenPoolShape.mark_rate_limited(token)
        end
      end

      defmodule TokenPoolShape do
        def mark_rate_limited(token, cooldown \\\\ 1_000)
        def mark_rate_limited(%{id: id}, _cooldown), do: id
      end
      """)

    assert [first, second] = by_kind(findings)
    assert first.message =~ "ResponseHandlerShape.handle_response/2"
    assert second.message =~ "ResponseHandlerShape.handle_response/3"
    assert first.message =~ "call requiring non-nil argument"
    assert second.message =~ "call requiring non-nil argument"
  end

  test "keeps dominating guards and nil clauses clean" do
    findings =
      smells("""
      defmodule GuardedToken do
        def caller do
          handle(nil, 429)
          normalize(nil)
        end

        def handle(token, status) do
          if status == 429 and not is_nil(token), do: token.name
        end

        def normalize(nil), do: :missing
        def normalize(token), do: token.name
      end
      """)

    assert by_kind(findings) == []
  end

  test "promotes direct defaults and late fallbacks but keeps routed collection paths as evidence" do
    findings =
      smells("""
      defmodule NilPromotionPolicy do
        def default_bug(options \\\\ nil), do: options.id

        def late_fallback(value), do: consume(value)
        def late_fallback(nil), do: :missing
        def consume(%{id: id}), do: id

        def collection_caller, do: render_fields(nil, [])

        def render_fields(view, fields) do
          for field <- fields, do: view.render(field)
        end

        def recursive_caller, do: recursive_default()

        defp recursive_default(value \\\\ nil, depth \\\\ 0) do
          if depth > 0, do: value.id, else: recursive_default(%{id: 1}, depth + 1)
        end
      end
      """)

    labels = Enum.map(by_kind(findings), & &1.message)
    assert Enum.any?(labels, &String.contains?(&1, "default_bug/1"))
    assert Enum.any?(labels, &String.contains?(&1, "late_fallback/1"))
    refute Enum.any?(labels, &String.contains?(&1, "render_fields/2"))
    refute Enum.any?(labels, &String.contains?(&1, "recursive_default/2"))
  end

  test "supports source suppression at the unsafe use" do
    findings =
      smells("""
      defmodule SuppressedNilUse do
        def caller, do: read(nil)

        def read(token) do
          # reach:disable-next-line nil_parameter_without_guard -- legacy nullable API
          token.name
        end
      end
      """)

    assert by_kind(findings) == []
  end

  defp by_kind(findings),
    do: Enum.filter(findings, &(&1.kind == :nil_parameter_without_guard))

  defp smells(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-nil-smell-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> List.wrap()
    |> Project.from_sources()
    |> Smells.run([])
  end
end
