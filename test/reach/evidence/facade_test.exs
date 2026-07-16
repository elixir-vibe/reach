defmodule Reach.Evidence.FacadeTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.Facade

  test "aggregates defdelegates and exact public forwarders by module" do
    project =
      project_from_source("""
      defmodule MyApp.API do
        alias MyApp.Implementation, as: Impl

        defdelegate fetch(id), to: Impl
        defdelegate list(opts \\\\ []), to: Impl
        def save(value), do: Impl.save(value)
        def local(value), do: {:ok, value}
      end

      defmodule MyApp.Implementation do
        def fetch(id), do: id
        def list(opts), do: opts
        def save(value), do: value
      end
      """)

    facade = Enum.find(Facade.collect_project(project), &(&1.module == "MyApp.API"))

    assert facade.public_function_count == 5
    assert facade.forwarder_count == 4
    assert facade.forwarder_ratio == 0.8
    assert facade.target_modules == ["MyApp.Implementation"]
    assert facade.boundary_markers == []
    assert facade.documented == false

    assert Enum.map(facade.forwarders, &{&1.function, &1.arity, &1.kind}) == [
             {:fetch, 1, :defdelegate},
             {:list, 0, :defdelegate},
             {:list, 1, :defdelegate},
             {:save, 1, :def}
           ]
  end

  test "does not classify mixed multi-clause functions as forwarders" do
    project =
      project_from_source("""
      defmodule MyApp.Mixed do
        def run(:special), do: :special
        def run(value), do: MyApp.Impl.run(value)
        defdelegate one(value), to: MyApp.Impl
        defdelegate two(value), to: MyApp.Impl
      end
      """)

    facade = Enum.find(Facade.collect_project(project), &(&1.module == "MyApp.Mixed"))

    assert facade.public_function_count == 3
    assert facade.forwarder_count == 2
    refute Enum.any?(facade.forwarders, &(&1.function == :run))
  end

  test "counts public macros and records intentional boundary markers" do
    project =
      project_from_source("""
      defmodule MyApp.BehaviourFacade do
        @moduledoc "An intentional integration facade."
        @behaviour Access
        use SomeFramework
        @deprecated "use MyApp.Impl"
        defdelegate one(value), to: MyApp.Impl
        defdelegate two(value), to: MyApp.Impl
        defdelegate three(value), to: MyApp.Impl
        defmacro routes(opts), do: MyApp.Impl.routes(opts)
      end
      """)

    facade = Enum.find(Facade.collect_project(project), &(&1.module == "MyApp.BehaviourFacade"))
    assert facade.public_function_count == 4
    assert facade.documented == true
    assert facade.boundary_markers == [:behaviour, :deprecated, :use]
  end

  test "ignores dynamic alias segments without crashing" do
    project =
      project_from_source("""
      defmodule MyApp.Dynamic do
        alias __MODULE__.Impl, as: LocalImpl
        defdelegate one(value), to: LocalImpl
        defdelegate two(value), to: LocalImpl
        defdelegate three(value), to: LocalImpl
      end
      """)

    assert [%Facade.Module{module: "MyApp.Dynamic"} = facade] = Facade.collect_project(project)
    assert facade.public_function_count == 3
    assert facade.forwarder_count == 0
  end

  defp project_from_source(source) do
    dir = Path.join(System.tmp_dir!(), "reach-facade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)
    Reach.Project.from_sources([path])
  end
end
