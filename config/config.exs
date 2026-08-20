import Config

if config_env() == :dev do
  config :volt,
    entry: "assets/js/app.ts",
    root: "assets",
    sources: ["**/*.{js,ts,vue}"],
    outdir: "priv/static",
    target: :es2020,
    sourcemap: false,
    hash: false,
    code_splitting: false,
    aliases: %{"@reach" => "assets/js"}
end
