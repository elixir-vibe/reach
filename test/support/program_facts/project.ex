defmodule Reach.Test.ProgramFacts.Project do
  @moduledoc false

  def with_project(program, fun) when is_function(fun, 2) do
    root =
      Path.join(System.tmp_dir!(), "reach_program_facts_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    try do
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)
      in_project(dir, fn -> fun.(dir, Reach.Project.from_mix_project()) end)
    after
      File.rm_rf!(root)
    end
  end

  def in_project(dir, fun) when is_function(fun, 0) do
    previous = File.cwd!()

    try do
      File.cd!(dir)
      fun.()
    after
      File.cd!(previous)
      Process.delete({Reach.CLI.Project, :func_index})
    end
  end
end
