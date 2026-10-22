defmodule Bluegreen.SixPNProbe do
  @moduledoc """
  Probes other flybg machines over 6PN and pages when this machine can't reach
  them.

  Every `@interval_ms` we resolve `<app>.internal`, pick one of the other
  machines at random and GET its health check. The address we pick is always
  logged. Any IPv4 answer fails the probe, since 6PN is IPv6 only.

  Peers come and go with every deploy, so a failure against an address that
  has dropped out of DNS by the time we look again is a peer that went away,
  not a 6PN failure, and doesn't count.

  There is one alert per region (`flybg-6pn-<region>`). Any machine that
  completes `@recovery_threshold` probes in a row resolves it, whether or not
  it triggered it, so an alert stays open until a machine in the region shows
  6PN working again.
  """
  use GenServer

  require Logger

  # Give the network a moment after boot before probing.
  @boot_grace_ms 30_000
  @interval_ms 60_000
  @request_timeout_ms 2_000
  @failure_threshold 4
  @recovery_threshold 3

  defmodule State do
    defstruct [
      :app,
      :machine_id,
      :region,
      :self_ip,
      :port,
      failures: 0,
      successes: 0,
      alerting: false,
      first_failure_at: nil,
      last_failure: nil
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %State{
      app: Keyword.fetch!(opts, :app),
      machine_id: Keyword.fetch!(opts, :machine_id),
      region: Keyword.get(opts, :region),
      self_ip: parse_ip(Keyword.get(opts, :self_ip)),
      port: Keyword.fetch!(opts, :port)
    }

    Process.send_after(self(), :probe, @boot_grace_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:probe, state) do
    result = probe(state)
    {state, action} = record(state, result, DateTime.utc_now())

    case action do
      :trigger -> Bluegreen.IncidentIo.trigger(dedup_key(state), alert_event(state))
      :resolve -> Bluegreen.IncidentIo.resolve(dedup_key(state), alert_event(state))
      :none -> :ok
    end

    Process.send_after(self(), :probe, @interval_ms)
    {:noreply, state}
  end

  @doc false
  # Applies one probe result to the state and decides whether to page. Public
  # only so the thresholds can be exercised directly in tests.
  def record(state, {:ok, _peer}, _now) do
    state = %{state | failures: 0, successes: state.successes + 1}

    # Resolve once per success streak, alerting or not: this is how a new
    # machine closes an alert left behind by one that was replaced.
    if state.successes == @recovery_threshold do
      {%{state | alerting: false, first_failure_at: nil, last_failure: nil}, :resolve}
    else
      {state, :none}
    end
  end

  def record(state, {:error, failure}, now) do
    state = %{
      state
      | failures: state.failures + 1,
        successes: 0,
        first_failure_at: state.first_failure_at || now,
        last_failure: failure
    }

    if not state.alerting and state.failures >= @failure_threshold do
      {%{state | alerting: true}, :trigger}
    else
      {state, :none}
    end
  end

  # Nothing to judge this round: no other machines, or the peer went away.
  def record(state, :skip, _now), do: {state, :none}

  defp probe(state) do
    host = "#{state.app}.internal"

    case resolve_peers(host, state.self_ip) do
      {:ok, []} ->
        Logger.info("6pn probe: no other machines in #{host}")
        :skip

      {:ok, peers} ->
        peer = Enum.random(peers)
        addr = "[#{format_ip(peer)}]:#{state.port}"
        Logger.info("6pn probe: querying #{addr}")

        case get(addr) do
          :ok ->
            {:ok, peer}

          {:error, reason} ->
            if peer_gone?(host, peer) do
              Logger.info("6pn probe: #{addr} failed (#{reason}) but left #{host}, ignoring")
              :skip
            else
              Logger.warning("6pn probe: #{addr} failed: #{reason}")
              {:error, %{peer: format_ip(peer), error: reason}}
            end
        end

      {:error, reason} ->
        Logger.warning("6pn probe: #{reason}")
        {:error, %{peer: nil, error: reason}}
    end
  end

  @doc false
  # Public only so the selection can be exercised directly in tests.
  def select_peers(v6, v4, self_ip) do
    case v4 do
      [] -> {:ok, Enum.reject(v6, &(&1 == self_ip))}
      [ip | _] -> {:error, "got IPv4 address #{format_ip(ip)}"}
    end
  end

  defp resolve_peers(host, self_ip) do
    name = String.to_charlist(host)

    case :inet_res.resolve(name, :in, :aaaa) do
      {:ok, _} ->
        v6 = :inet_res.lookup(name, :in, :aaaa)
        v4 = :inet_res.lookup(name, :in, :a)

        case select_peers(v6, v4, self_ip) do
          {:ok, peers} -> {:ok, peers}
          {:error, reason} -> {:error, "#{reason} for #{host}"}
        end

      {:error, reason} ->
        {:error, "failed to resolve #{host}: #{inspect(reason)}"}
    end
  end

  defp peer_gone?(host, peer) do
    peer not in :inet_res.lookup(String.to_charlist(host), :in, :aaaa)
  end

  defp get(addr) do
    :get
    |> Finch.build("http://#{addr}/healthcheck")
    |> Finch.request(Bluegreen.Finch,
      receive_timeout: @request_timeout_ms,
      pool_timeout: @request_timeout_ms
    )
    |> case do
      {:ok, %Finch.Response{status: 200}} -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, "unexpected status #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp dedup_key(state), do: "flybg-6pn-#{state.region}"

  @doc false
  # Public so the payload shape can be asserted in tests.
  def alert_event(state) do
    %{
      title: "flybg 6PN unreachable in #{state.region}",
      description:
        "flybg machine #{state.machine_id} (#{state.region}) can't reach other flybg " <>
          "machines over 6PN.",
      # Alert routes read severity and region from here; incident.io cannot see
      # anything at the top level of the payload.
      metadata: %{
        severity: "error",
        team: "platform",
        source: "#{state.app}/#{state.machine_id}",
        machine_id: state.machine_id,
        region: state.region,
        self_6pn: state.self_ip && format_ip(state.self_ip),
        peer: state.last_failure[:peer],
        error: state.last_failure[:error],
        consecutive_failures: state.failures,
        first_failure_at: state.first_failure_at,
        find_host: "corrosion: SELECT node FROM machines WHERE id = '#{state.machine_id}'"
      }
    }
  end

  defp parse_ip(nil), do: nil

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} -> addr
      {:error, _} -> nil
    end
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
