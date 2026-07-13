defmodule Reach.CLI.Format do
  @moduledoc false

  alias Reach.CLI.Project
  alias Reach.Effects

  # ── Color helpers ──

  defp color?, do: IO.ANSI.enabled?()

  defp c(text, ansi) do
    if color?(), do: [ansi, text, IO.ANSI.reset()] |> IO.iodata_to_binary(), else: text
  end

  def cyan(text), do: c(text, IO.ANSI.cyan())
  def green(text), do: c(text, IO.ANSI.green())
  def yellow(text), do: c(text, IO.ANSI.yellow())
  def red(text), do: c(text, IO.ANSI.red())
  def magenta(text), do: c(text, IO.ANSI.magenta())
  def blue(text), do: c(text, IO.ANSI.blue())
  def bright(text), do: c(text, IO.ANSI.bright())
  def faint(text), do: c(text, IO.ANSI.faint())

  @type risk :: :high | :medium | :low

  @spec risk(risk()) :: String.t()
  def risk(:high), do: red("high")
  def risk(:medium), do: yellow("medium")
  def risk(:low), do: green("low")

  @spec effect(Effects.effect()) :: String.t()
  def effect(:pure), do: green("pure")
  def effect(:unknown), do: yellow("unknown")
  def effect(:io), do: cyan("io")
  def effect(:read), do: blue("read")
  def effect(:write), do: magenta("write")
  def effect(:exception), do: red("exception")
  def effect(:send), do: magenta("send")
  def effect(:receive), do: magenta("receive")
  def effect(:nif), do: red("nif")

  @spec effects_join([Effects.effect()], String.t()) :: String.t()
  def effects_join(effects, separator \\ ", ") do
    Enum.map_join(effects, separator, &effect/1)
  end

  def humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  def humanized_join(values, separator \\ ", ") do
    Enum.map_join(values, separator, &humanize/1)
  end

  # ── Rendering ──

  def render(findings, tool, opts) do
    case opts[:format] || "text" do
      "text" -> render_text(findings, tool)
      "json" -> render_json(findings, tool, opts)
      "oneline" -> render_oneline(findings)
    end
  end

  defp render_text(findings, _tool) do
    IO.write(findings)
  end

  defp render_json(data, tool, _opts) do
    output = %Reach.CLI.JSONEnvelope{command: tool, tool: tool, data: data}

    json = JSON.encode!(output)
    IO.write(json)
    IO.write("\n")
  end

  defp render_oneline(findings) when is_list(findings) do
    Enum.each(findings, &IO.puts/1)
  end

  defp render_oneline(findings) do
    IO.write(findings)
  end

  # ── Formatting ──

  def location(node) do
    case node.source_span do
      %{file: f, start_line: l} ->
        loc(f, l)

      _ ->
        "unknown"
    end
  end

  def loc(file, line) when is_binary(file) do
    faint(path(file) <> ":" <> to_string(line))
  end

  def loc(raw, _), do: faint(to_string(raw))

  def location_text("unknown"), do: "unknown"

  def location_text(%{file: file, line: line}) when is_binary(file) do
    loc(file, line)
  end

  def location_text(%{file: file, start_line: line}) when is_binary(file) do
    loc(file, line)
  end

  def location_text(location) when is_binary(location) do
    case Regex.run(~r/^(.*):(\d+)$/, location) do
      [_match, file, line] -> loc(file, line)
      _ -> faint(location)
    end
  end

  def location_text(location), do: faint(to_string(location))

  def path(file) when is_binary(file) do
    expanded = Path.expand(file)

    case Project.display_root() do
      nil -> file
      root -> relative_to_root(expanded, root)
    end
  end

  def path(other), do: to_string(other)

  defp relative_to_root(path, root) do
    relative = Path.relative_to(path, root)

    if String.starts_with?(relative, ".."), do: path, else: relative
  end

  def header(title) do
    width = max(String.length(title) + 4, 40)
    line = cyan(String.duplicate("─", width))
    "\n#{line}\n  #{bright(title)}\n#{line}"
  end

  def section(title) do
    "\n#{cyan(title)}\n#{cyan(String.duplicate("─", String.length(title)))}"
  end

  def tree_line(item, last?) do
    prefix = if last?, do: "└── ", else: "├── "
    "#{faint(prefix)}#{item}"
  end

  def indent(text, n \\ 2) do
    pad = String.duplicate(" ", n)

    text
    |> String.split("\n")
    |> Enum.map(fn line -> [pad, line] end)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  def tag(:warning), do: yellow("⚠")
  def tag(:error), do: red("✗")
  def tag(:ok), do: green("✓")
  def tag(:info), do: cyan("ℹ")

  def warning(text), do: yellow(text) <> " " <> tag(:warning)
  def omitted(text), do: faint("… " <> text)
  def empty(text \\ "none"), do: faint("(#{text})")
  def count(n), do: bright(to_string(n))
  def summary(text), do: faint(text)

  def threshold_color(value, warn, crit) do
    cond do
      value >= crit -> red(to_string(value))
      value >= warn -> yellow(to_string(value))
      true -> to_string(value)
    end
  end
end
