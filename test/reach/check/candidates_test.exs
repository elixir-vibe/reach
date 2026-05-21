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
