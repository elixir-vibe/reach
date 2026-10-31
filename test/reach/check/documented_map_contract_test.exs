defmodule Reach.Check.DocumentedMapContractTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Candidates

  @fields "timeout: integer(), retries: integer(), mode: atom()"

  for kind <- [:type, :typep], return <- ["config()", "config() | nil", "nil | config()"] do
    test "recognizes #{kind} with return #{return}" do
      result =
        candidates(
          "@#{unquote(kind)} config :: %{#{@fields}}",
          "@spec normalize(term()) :: #{unquote(return)}"
        )

      refute Enum.any?(result, &(&1.kind == :introduce_typed_map_contract))
    end
  end

  for {name, declaration, spec} <- [
        {"missing", "", ""},
        {"generic", "", "@spec normalize(term()) :: map()"},
        {"wrong keys", "@type config :: %{timeout: integer(), retries: integer(), other: atom()}",
         "@spec normalize(term()) :: config()"},
        {"other type", "@type config :: %{timeout: integer(), retries: integer(), mode: atom()}",
         "@spec normalize(term()) :: other()"},
        {"other function",
         "@type config :: %{timeout: integer(), retries: integer(), mode: atom()}",
         "@spec consume(term()) :: config()"},
        {"wrong arity", "@type config :: %{timeout: integer(), retries: integer(), mode: atom()}",
         "@spec normalize(term(), term()) :: config()"},
        {"remote type", "@type config :: %{timeout: integer(), retries: integer(), mode: atom()}",
         "@spec normalize(term()) :: Other.config()"},
        {"open union", "@type config :: %{timeout: integer(), retries: integer(), mode: atom()}",
         "@spec normalize(term()) :: config() | term()"},
        {"optional key",
         "@type config :: %{optional(:timeout) => integer(), retries: integer(), mode: atom()}",
         "@spec normalize(term()) :: config()"}
      ] do
    test "retains advice for #{name}" do
      result = candidates(unquote(declaration), unquote(spec))
      assert Enum.any?(result, &(&1.kind == :introduce_typed_map_contract))
    end
  end

  test "recognizes explicit required literal keys" do
    declaration =
      "@type config :: %{required(:timeout) => integer(), required(:retries) => integer(), required(:mode) => atom()}"

    result = candidates(declaration, "@spec normalize(term()) :: config()")
    refute Enum.any?(result, &(&1.kind == :introduce_typed_map_contract))
  end

  test "documented groups do not consume the candidate limit" do
    extra = """
    def other(input) do
      config = %{x: input.x, y: input.y, z: input.z}
      config.x
      config.y
      config
    end
    def other_consumer(input) do
      config = other(input)
      config.x
      config.z
    end
    """

    result =
      candidates(
        "@type config :: %{#{@fields}}",
        "@spec normalize(term()) :: config()",
        extra,
        "config",
        candidates: [limits: [per_kind: 1]]
      )

    candidate = Enum.find(result, &(&1.kind == :introduce_typed_map_contract))
    assert candidate
    assert candidate.keys == ["x", "y", "z"]
  end

  test "retains an independent untyped producer in the same shape group" do
    extra = """
    def independent(input) do
      config = %{timeout: input.timeout, retries: input.retries, mode: input.mode}
      config.timeout
      config.retries
      config
    end
    """

    result =
      candidates("@type config :: %{#{@fields}}", "@spec normalize(term()) :: config()", extra)

    assert Enum.any?(result, &(&1.kind == :introduce_typed_map_contract))
  end

  test "retains a shape variant" do
    extra = """
    def variant(input) do
      config = %{timeout: input.timeout, retries: input.retries, mode: input.mode, extra: true}
      config.timeout
      config.retries
      config
    end
    """

    result =
      candidates("@type config :: %{#{@fields}}", "@spec normalize(term()) :: config()", extra)

    assert Enum.any?(result, &(&1.kind == :introduce_typed_map_contract))
  end

  test "a named map does not discharge struct advice" do
    result =
      candidates(
        "@type config :: %{#{@fields}}",
        "@spec normalize(term()) :: config()",
        "",
        "profile"
      )

    assert Enum.any?(result, &(&1.kind == :introduce_struct_contract))
  end

  defp candidates(declaration, spec, extra \\ "", variable \\ "config", policy \\ []) do
    dir =
      Path.join(System.tmp_dir!(), "reach-documented-map-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "options.ex")

    File.write!(path, """
    defmodule DocumentedOptions do
      #{declaration}
      #{spec}
      def normalize(nil), do: nil
      def normalize(input) do
        #{variable} = %{timeout: input.timeout, retries: input.retries, mode: input.mode}
        #{variable}.timeout
        #{variable}.retries
        #{variable}
      end
      def consume(input) do
        #{variable} = normalize(input)
        #{variable}.mode
        #{variable}.timeout
      end
      #{extra}
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    Candidates.run(project, policy, top: 100).candidates
  end
end
