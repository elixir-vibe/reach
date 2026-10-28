defmodule Reach.Plugins.Phoenix.Smells.PubSubPayloadRefetchTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Plugins.{Ecto, Phoenix}
  alias Reach.Smell.Finding

  @kind :phoenix_pubsub_payload_refetch

  @context ~S'''
  defmodule MyApp.Fleet do
    @pubsub MyApp.PubSub
    @topic "instances"

    def get_instance(id), do: MyApp.Repo.get(MyApp.Fleet.Instance, id)

    def broadcast_instance(%MyApp.Fleet.Instance{} = instance) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:instance, instance})
    end
  end
  '''

  test "flags a handler that refetches a record the broadcaster already sent" do
    findings =
      run(@context, ~S'''
      defmodule MyAppWeb.InstanceLive do
        def handle_info({:instance, %{id: id}}, socket) do
          case MyApp.Fleet.get_instance(id) do
            nil -> {:noreply, socket}
            instance -> {:noreply, assign(socket, instance: instance)}
          end
        end
      end
      ''')

    assert [%Finding{kind: @kind, confidence: :medium} = finding] = findings
    assert finding.message =~ "handle_info/2 for {:instance, _}"
    assert finding.message =~ "already sends the record"
    assert [broadcaster] = finding.evidence
    assert finding.message =~ broadcaster
    assert finding.location =~ ~r/:3$/
  end

  test "flags struct and ignored-match id patterns" do
    findings =
      run(@context, ~S'''
      defmodule MyAppWeb.InstanceLive do
        def handle_info({:instance, %MyApp.Fleet.Instance{id: id}}, socket) do
          {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
        end
      end

      defmodule MyAppWeb.OtherLive do
        def handle_info({:instance, %{id: id} = _instance}, socket) do
          {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
        end
      end
      ''')

    assert [%Finding{kind: @kind}, %Finding{kind: @kind}] = findings
  end

  test "follows one local broadcast wrapper" do
    findings =
      run(
        ~S'''
        defmodule MyApp.Fleet do
          def get_instance(id), do: MyApp.Repo.get(MyApp.Fleet.Instance, id)

          def update_instance(instance) do
            broadcast({:instance, instance})
          end

          defp broadcast(message), do: Phoenix.PubSub.broadcast(MyApp.PubSub, "instances", message)
        end
        ''',
        ~S'''
        defmodule MyAppWeb.InstanceLive do
          def handle_info({:instance, %{id: id}}, socket) do
            {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
          end
        end
        '''
      )

    assert [%Finding{kind: @kind}] = findings
  end

  test "allows id-only payloads" do
    findings =
      run(
        ~S'''
        defmodule MyApp.Fleet do
          def get_instance(id), do: MyApp.Repo.get(MyApp.Fleet.Instance, id)

          def broadcast_instance(instance) do
            Phoenix.PubSub.broadcast(MyApp.PubSub, "instances", {:instance, instance.id})
            Phoenix.PubSub.broadcast(MyApp.PubSub, "instances", {:instance, %{id: instance.id}})
          end

          def broadcast_by_id(instance_id) do
            Phoenix.PubSub.broadcast(MyApp.PubSub, "instances", {:instance, instance_id})
          end
        end
        ''',
        ~S'''
        defmodule MyAppWeb.InstanceLive do
          def handle_info({:instance, %{id: id}}, socket) do
            {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
          end

          def handle_info({:instance, id}, socket) do
            {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
          end
        end
        '''
      )

    assert findings == []
  end

  test "allows handlers that use other payload fields" do
    findings =
      run(@context, ~S'''
      defmodule MyAppWeb.InstanceLive do
        def handle_info({:instance, %{id: id, status: status}}, socket) do
          {:noreply, assign(socket, status: status, instance: MyApp.Fleet.get_instance(id))}
        end

        def handle_info({:instance, %{id: id} = instance}, socket) do
          fresh = MyApp.Fleet.get_instance(id)
          {:noreply, assign(socket, previous: instance, instance: fresh)}
        end
      end
      ''')

    assert findings == []
  end

  test "allows handlers that do not query with the id" do
    findings =
      run(@context, ~S'''
      defmodule MyAppWeb.InstanceLive do
        def handle_info({:instance, %{id: id}}, socket) do
          {:noreply, assign(socket, selected_id: id)}
        end
      end
      ''')

    assert findings == []
  end

  test "allows handlers that pass the id only to writes or pure helpers" do
    findings =
      run(
        ~S'''
        defmodule MyApp.Fleet do
          def mark_seen(id), do: MyApp.Repo.update_all(MyApp.Fleet.Instance, set: [seen_id: id])

          def broadcast_instance(instance) do
            Phoenix.PubSub.broadcast(MyApp.PubSub, "instances", {:instance, instance})
          end
        end
        ''',
        ~S'''
        defmodule MyAppWeb.InstanceLive do
          def handle_info({:instance, %{id: id}}, socket) do
            MyApp.Fleet.mark_seen(id)
            {:noreply, assign(socket, label: Integer.to_string(id))}
          end
        end
        '''
      )

    assert findings == []
  end

  test "skips handlers without a matching broadcaster" do
    findings =
      run(@context, ~S'''
      defmodule MyAppWeb.InstanceLive do
        def handle_info({:other_tag, %{id: id}}, socket) do
          {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
        end
      end
      ''')

    assert findings == []
  end

  test "ignores functions other than handle_info/2" do
    findings =
      run(@context, ~S'''
      defmodule MyAppWeb.InstanceLive do
        def handle_event({:instance, %{id: id}}, socket) do
          {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
        end

        def handle_info({:instance, %{id: id}}, socket, _extra) do
          {:noreply, assign(socket, instance: MyApp.Fleet.get_instance(id))}
        end
      end
      ''')

    assert findings == []
  end

  defp run(context, receiver) do
    project =
      [context, receiver]
      |> Enum.map(&write_source/1)
      |> Reach.Project.from_sources(plugins: [Phoenix, Ecto])

    project
    |> Smells.run()
    |> Enum.filter(&(&1.kind == @kind))
  end

  defp write_source(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-pubsub-payload-refetch-#{System.unique_integer()}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
