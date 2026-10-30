defmodule Reach.Effects.IodataInferenceTest do
  use ExUnit.Case, async: false

  # Project inference shares the named effect-classification cache.
  test "conversion adds no IO and preserves input and subsequent IO effects" do
    path = Path.join(System.tmp_dir!(), "reach-iodata-#{System.unique_integer([:positive])}.ex")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, """
    defmodule IodataInferenceExample do
      def pure(data), do: IO.iodata_to_binary(data)
      def read(path), do: IO.iodata_to_binary(File.read!(path))
      def write(path, data), do: File.write!(path, IO.iodata_to_binary(data))
      def print(data), do: IO.puts(IO.iodata_to_binary(data))
      def unknown(data), do: UnknownIodataProducer.load(IO.iodata_to_binary(data))
      def error, do: IO.iodata_to_binary(raise ArgumentError)
    end

    defmodule IodataInferenceCaller do
      def pure(data), do: IodataInferenceExample.pure(data)
      def read(path), do: IodataInferenceExample.read(path)
      def write(path, data), do: IodataInferenceExample.write(path, data)
      def print(data), do: IodataInferenceExample.print(data)
      def unknown(data), do: IodataInferenceExample.unknown(data)
      def error, do: IodataInferenceExample.error()
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])

    for {name, expected} <- [
          pure: :pure,
          read: :read,
          write: :write,
          print: :io,
          unknown: :unknown,
          error: :exception
        ] do
      call =
        Enum.find(Map.values(project.nodes), fn node ->
          node.type == :call and node.meta[:module] == IodataInferenceExample and
            node.meta[:function] == name
        end)

      assert call
      assert Reach.Effects.classify(call, []) == expected
    end
  end
end
