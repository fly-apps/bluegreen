defmodule Bluegreen.SixPNProbeTest do
  use ExUnit.Case, async: true

  alias Bluegreen.SixPNProbe
  alias Bluegreen.SixPNProbe.State

  @self {0xFDAA, 0, 0, 0, 0, 0, 0, 2}
  @peer {0xFDAA, 0, 0, 0, 0, 0, 1, 2}
  @failure {:error, %{peer: "fdaa::1:2", error: "timeout"}}

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
end
