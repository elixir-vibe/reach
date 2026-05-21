defmodule Reach.Check.CandidatesTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Candidates

  test "reports repeated implicit map contracts as advisory struct candidates" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "profiles.ex")

    File.write!(path, """
    defmodule Profiles do
      def build(user) do
        profile = %{id: user.id, name: user.name, email: user.email}
        profile.id
        profile.email
      end

      def profile(user) do
        %{id: user.id, name: user.name, email: user.email}
      end

      def render(user) do
        data = profile(user)
        data.id
        Map.get(data, :email)
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    result = Candidates.run(project, [], top: 10)

    candidate =
      Enum.find(result.candidates, fn candidate ->
        candidate.kind == :introduce_struct_contract and
          candidate.target == "map shape [:email, :id, :name]"
      end)

    assert candidate
    assert candidate.keys == ["email", "id", "name"]
    assert candidate.occurrences == 2
    assert "local" in candidate.sources
    assert "return" in candidate.sources

    File.rm_rf(dir)
  end

  test "groups similar map shapes as one contract family candidate" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "profiles.ex")

    File.write!(path, """
    defmodule Profiles do
      def card(user) do
        %{id: user.id, name: user.name, email: user.email}
      end

      def export(user) do
        %{id: user.id, name: user.name, email: user.email, inserted_at: user.inserted_at}
      end

      def render(user) do
        card = card(user)
        card.id
        card.email

        export = export(user)
        export.id
        export.email
        export.inserted_at
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    result = Candidates.run(project, [], top: 10)

    candidate =
      Enum.find(result.candidates, fn candidate ->
        candidate.kind == :introduce_struct_contract and
          String.starts_with?(candidate.target, "map shape family")
      end)

    assert candidate
    assert candidate.keys == ["email", "id", "name"]
    assert candidate.occurrences == 2
    assert Enum.any?(candidate.evidence, &String.contains?(&1, "inserted_at"))

    File.rm_rf(dir)
  end

  test "promotes repeated maps encoded by Jason as boundary contract candidates" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "json_payloads.ex")

    File.write!(path, """
    defmodule JsonPayloads do
      def first(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.email
        Jason.encode!(data)
      end

      def second(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.name
        Jason.encode(data)
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [Reach.Plugins.Jason])
    result = Candidates.run(project, [], top: 10)

    candidate = Enum.find(result.candidates, &(&1.kind == :introduce_boundary_contract))

    assert candidate
    assert candidate.keys == ["email", "id", "name"]

    File.rm_rf(dir)
  end

  test "promotes repeated payload maps as boundary contract candidates" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "payloads.ex")

    File.write!(path, """
    defmodule Payloads do
      def first(user) do
        payload = %{id: user.id, name: user.name, email: user.email}
        payload.id
        payload.email
      end

      def second(user) do
        payload = %{id: user.id, name: user.name, email: user.email}
        payload.id
        payload.name
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    result = Candidates.run(project, [], top: 10)

    candidate = Enum.find(result.candidates, &(&1.kind == :introduce_boundary_contract))

    assert candidate
    assert candidate.actionability == :review_boundary_contract
    assert candidate.keys == ["email", "id", "name"]
    assert candidate.suggestion =~ "boundary contract"

    File.rm_rf(dir)
  end

  test "promotes repeated options maps as typed map contract candidates" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "options.ex")

    File.write!(path, """
    defmodule Options do
      def first(input) do
        opts = %{timeout: input.timeout, retries: input.retries, mode: input.mode}
        opts.timeout
        opts.retries
      end

      def second(input) do
        opts = %{timeout: input.timeout, retries: input.retries, mode: input.mode}
        opts.mode
        opts.timeout
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    result = Candidates.run(project, [], top: 10)

    candidate = Enum.find(result.candidates, &(&1.kind == :introduce_typed_map_contract))

    assert candidate
    assert candidate.actionability == :review_options_contract
    assert candidate.keys == ["mode", "retries", "timeout"]
    assert candidate.suggestion =~ "typed map"

    File.rm_rf(dir)
  end

  test "does not promote low-signal escaped maps as struct candidates" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "payloads.ex")

    File.write!(path, """
    defmodule Payloads do
      def build(user) do
        %{id: user.id, name: user.name, email: user.email, role: user.role}
      end

      def send(user) do
        payload = build(user)
        payload.id
        HTTP.post(payload)
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    result = Candidates.run(project, [], top: 10)

    refute Enum.any?(result.candidates, &(&1.kind == :introduce_struct_contract))

    File.rm_rf(dir)
  end

  test "does not promote template assigns maps as struct candidates" do
    dir = Path.join(System.tmp_dir!(), "reach-candidates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "emails.ex")

    File.write!(path, """
    defmodule Emails do
      def template_assigns(input) do
        %{
          branding: input.branding,
          customer: input.customer,
          subject: input.subject,
          to: input.to
        }
      end

      def render(input) do
        assigns = template_assigns(input)
        assigns.branding
        assigns.customer
        assigns.subject
        assigns.to
      end
    end
    """)

    project = Reach.Project.from_sources([path], plugins: [])
    result = Candidates.run(project, [], top: 10)

    refute Enum.any?(result.candidates, &(&1.kind == :introduce_struct_contract))

    File.rm_rf(dir)
  end
end
