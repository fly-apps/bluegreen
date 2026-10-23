defmodule Bluegreen.SixPNProbe do
  @moduledoc """
  Probes other flybg machines over 6PN and publishes how badly it is going.

  Every `@interval_ms` we resolve `<app>.internal`, pick one of the other
  machines at random and open a TCP connection to it. The address we pick is
  always logged. Any IPv4 answer fails the probe, since 6PN is IPv6 only.

  A refused connection counts as a success: the packet crossed 6PN and
  something answered. Whether the peer's app is healthy is a different
  question, and Fly's own health checks already ask it.

  Peers come and go with every deploy, so a failure against an address that
  has dropped out of DNS by the time we look again is a peer that went away,
  not a 6PN failure, and doesn't count.

  This GenServer decides nothing about paging. It exports the consecutive
  failure count as `fly_flybg_6pn_consecutive_failures` (see
  `Bluegreen.SixPNProbe.PromExPlugin`) and the alert lives in
  superfly/squawk-checks as `flybg_6pn_unreachable`, which thresholds
  `max by (region)` of the gauge. Two consequences worth knowing:

  - A machine that is replaced mid-failure stops exporting, so its series goes
    stale and the alert clears itself. The old per-region dedup key existed to
    get that same property by hand.
  - A region stays alerting while *any* machine in it is still failing, which
    is what the cross-machine recovery rule was reaching for.
  """
  use GenServer

  alias Bluegreen.SixPNProbe.PromExPlugin

  require Logger

  # Give the network a moment after boot before probing.
  @boot_grace_ms 30_000
  @interval_ms 60_000
  @connect_timeout_ms 2_000

  defmodule State do
    defstruct [
      :app,
      :self_ip,
      :port,
      failures: 0
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # No machine id or region here: Fly's Prometheus stamps `instance`, `region`
    # and `app` onto every scraped series, so the probe would only be competing
    # with the scraper for those labels.
    state = %State{
      app: Keyword.fetch!(opts, :app),
      self_ip: parse_ip(Keyword.get(opts, :self_ip)),
      port: Keyword.fetch!(opts, :port)
    }

    Process.send_after(self(), :probe, @boot_grace_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:probe, state) do
    state = record(state, probe(state))
    PromExPlugin.execute_probe_metrics(state.failures)

    Process.send_after(self(), :probe, @interval_ms)
    {:noreply, state}
  end

  @doc false
  # Applies one probe result to the failure streak. Public only so it can be
  # exercised directly in tests.
  def record(state, {:ok, _peer}), do: %{state | failures: 0}

  def record(state, {:error, _failure}), do: %{state | failures: state.failures + 1}

  # Nothing to judge this round: no other machines, or the peer went away. The
  # streak is held rather than reset — we learned nothing either way, and the
  # gauge keeps reporting the last thing we did learn.
  def record(state, :skip), do: state

  defp probe(state) do
    host = "#{state.app}.internal"

    case resolve_peers(host, state.self_ip) do
      {:ok, []} ->
        Logger.info("6pn probe: no other machines in #{host}")
        :skip

      {:ok, peers} ->
        peer = Enum.random(peers)
        addr = "[#{format_ip(peer)}]:#{state.port}"
        Logger.info("6pn probe: connecting to #{addr}")

        case connect(peer, state.port) do
          :ok ->
            {:ok, peer}

          :refused ->
            Logger.info("6pn probe: #{addr} refused the connection, so 6PN is up")
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

  @doc false
  # Connects to the peer's address instead of a URL built from it. Formatting
  # the tuple into `http://[fdaa:...]:8080` made the address a *hostname*: an
  # HTTP client resolved it with the IPv4 family, failed in about a
  # millisecond with nxdomain, and no packet ever crossed 6PN. The tuple we
  # already hold from DNS needs no resolver, and its size picks the family.
  #
  # Public so a test can prove we can reach an IPv6 literal at all, which is
  # the part that was broken.
  def connect(peer, port) do
    case :gen_tcp.connect(peer, port, [active: false], @connect_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      # A refusal is a round trip: the packet crossed 6PN and something sent a
      # reset back. It says nothing about the peer's health, but 6PN is the
      # only thing this probe asks about. flybg auto-stops its machines, so
      # most peers are not listening and this is the ordinary case.
      {:error, :econnrefused} ->
        :refused

      {:error, reason} ->
        {:error, reason}
    end
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
