defmodule Reach.CLI.Render.Report do
  @moduledoc false

  alias Reach.CLI.Requirements

  @priv_dir Application.app_dir(:reach, "priv")

  @template_path Path.join(@priv_dir, "template.html.eex")
  @js_bundle_path Path.join([@priv_dir, "static", "js", "reach.js"])
  @css_bundle_path Path.join([@priv_dir, "static", "js", "reach.css"])

  for path <- [@template_path, @js_bundle_path, @css_bundle_path] do
    @external_resource path
  end

  @template File.read!(@template_path)
  @js_bundle File.read!(@js_bundle_path)
  @css_bundle File.read!(@css_bundle_path)

  def render("html", graph_data, _graph, output_dir, opts),
    do: render_html(graph_data, output_dir, opts)

  def render("dot", _graph_data, graph, output_dir, _opts), do: render_dot(graph, output_dir)

  def render("json", graph_data, _graph, output_dir, _opts),
    do: render_json(graph_data, output_dir)

  defp render_html(graph_data, output_dir, opts) do
    Requirements.json!("HTML/JSON output")

    File.mkdir_p!(output_dir)

    graph_json = JSON.encode!(graph_data)
    makeup_css = Reach.Visualize.makeup_stylesheet()

    html =
      EEx.eval_string(@template,
        graph_json: graph_json,
        js_bundle: @js_bundle,
        css_bundle: @css_bundle,
        makeup_css: makeup_css,
        file: nil,
        module: nil
      )

    path = Path.join(output_dir, "index.html")
    File.write!(path, html)

    Mix.shell().info("Reach report: #{path}")

    if Keyword.get(opts, :open, true), do: open_browser(path)
  end

  defp render_dot(graph, output_dir) do
    File.mkdir_p!(output_dir)
    path = Path.join(output_dir, "reach.dot")

    {:ok, dot} = Reach.to_dot(graph)
    File.write!(path, dot)

    Mix.shell().info("DOT file: #{path}")
  end

  defp render_json(graph_data, output_dir) do
    Requirements.json!("HTML/JSON output")

    File.mkdir_p!(output_dir)
    path = Path.join(output_dir, "reach.json")

    File.write!(path, JSON.encode!(graph_data))

    Mix.shell().info("JSON file: #{path}")
  end

  defp open_browser(path) do
    abs = Path.expand(path)

    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [abs], stderr_to_stdout: true)
      {:unix, _} -> System.cmd("xdg-open", [abs], stderr_to_stdout: true)
      {:win32, _} -> System.cmd("cmd", ["/c", "start", "", abs], stderr_to_stdout: true)
    end
  end
end
