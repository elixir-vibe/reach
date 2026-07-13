unless Code.ensure_loaded?(Boxart) do
  ExUnit.configure(exclude: [:boxart])
end

ExUnit.start()
