defmodule Bluegreen.SixPNProbeTest do
  use ExUnit.Case, async: true

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Bluegreen.SixPNProbe
  alias Bluegreen.SixPNProbe.State

  @self {0xFDAA, 0, 0, 0, 0, 0, 0, 2}
  @peer {0xFDAA, 0, 0, 0, 0, 0, 1, 2}
  @failure {:error, %{peer: "fdaa::1:2", error: "timeout"}}
  @loopback {0, 0, 0, 0, 0, 0, 0, 1}

  defp streak(results) do
    Enum.reduce(results, %State{}, &SixPNProbe.record(&2, &1))
  end

  describe "record/2" do
    test "counts failures in a row" do
      assert streak(List.duplicate(@failure, 6)).failures == 6
    end

    test "a success clears the streak" do
      results = [@failure, @failure, @failure, {:ok, @peer}, @failure]

      assert streak(results).failures == 1
    end

    # We learned nothing this round, so reporting a healthy 0 would be a lie —
    # and on an app redeployed every 15 minutes, "no peers yet" is common.
    test "a skipped probe holds the streak where it was" do
      assert streak([@failure, @failure, :skip, :skip]).failures == 2
    end
  end

  describe "select_peers/3" do
    test "excludes this machine" do
      assert {:ok, [@peer]} = SixPNProbe.select_peers([@self, @peer], [], @self)
    end

    test "fails on any IPv4 answer" do
      assert {:error, "got IPv4 address 10.0.0.1"} =
               SixPNProbe.select_peers([@peer], [{10, 0, 0, 1}], @self)
    end
  end

  # The bug this replaced: the probe formatted the peer tuple into
  # http://[fdaa:...]:8080 and handed it to Finch, which resolved it as a
  # hostname with the IPv4 family. Every probe failed in about a millisecond
  # with nxdomain, so 6PN was never tested at all. These two cases are over
  # IPv6 literals on purpose.
  describe "connect/2" do
    test "reaches a peer that is listening" do
      {:ok, listener} = :gen_tcp.listen(0, [:inet6, ip: @loopback, active: false])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert SixPNProbe.connect(@loopback, port) == :ok
    end

    test "a refusal is a round trip, not a 6PN failure" do
      # Bind and release, so the port is almost certainly closed but routable.
      {:ok, listener} = :gen_tcp.listen(0, [:inet6, ip: @loopback, active: false])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)

      assert SixPNProbe.connect(@loopback, port) == :refused
    end
  end
end
