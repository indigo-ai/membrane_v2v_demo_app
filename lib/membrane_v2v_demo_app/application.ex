defmodule MembraneV2vDemoApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MembraneV2vDemoAppWeb.Telemetry,
      # MembraneV2vDemoApp.Repo,
      {DNSCluster,
       query: Application.get_env(:membrane_v2v_demo_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MembraneV2vDemoApp.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: MembraneV2vDemoApp.Finch},
      # Start a worker by calling: MembraneV2vDemoApp.Worker.start_link(arg)
      # {MembraneV2vDemoApp.Worker, arg},
      # Start to serve requests, typically the last entry
      MembraneV2vDemoAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MembraneV2vDemoApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MembraneV2vDemoAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
