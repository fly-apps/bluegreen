defmodule Bluegreen.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BluegreenWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bluegreen, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bluegreen.PubSub},
      # Start the Finch HTTP client for sending emails, paging and the 6PN
      # probe. Mint's default 30s connect timeout would stall the probe on a
      # broken 6PN path, so keep connects short.
      {Finch,
       name: Bluegreen.Finch, pools: %{default: [conn_opts: [transport_opts: [timeout: 2_000]]]}},
      # Start a worker by calling: Bluegreen.Worker.start_link(arg)
      # {Bluegreen.Worker, arg},
      # Start to serve requests, typically the last entry
      BluegreenWeb.Endpoint
    ]

    # Probe other machines over 6PN, only where it's configured (on Fly). It
    # starts last so it stops first on shutdown, while Finch is still up to
    # resolve its alert.
    children =
      case Application.get_env(:bluegreen, Bluegreen.SixPNProbe) do
        nil -> children
        opts -> children ++ [{Bluegreen.SixPNProbe, opts}]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bluegreen.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BluegreenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
