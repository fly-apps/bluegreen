defmodule Bluegreen.SixPNProbeTest do
  use ExUnit.Case, async: true

  alias Bluegreen.SixPNProbe
  alias Bluegreen.SixPNProbe.State

  @now ~U[2026-10-21 12:00:00Z]
  @self {0xFDAA, 0, 0, 0, 0, 0, 0, 2}
  @peer {0xFDAA, 0, 0, 0, 0, 0, 1, 2}
  @failure {:error, %{peer: "fdaa::1:2", error: "timeout"}}

  defp apply_results(state, results) do
    Enum.reduce(results, {state, []}, fn result, {state, actions} ->
      {state, action} = SixPNProbe.record(state, result, @now)
      {state, actions ++ [action]}
    end)
  end

  describe "record/3" do
    test "triggers after four failures in a row" do
      {state, actions} = apply_results(%State{}, List.duplicate(@failure, 6))

      assert actions == [:none, :none, :none, :trigger, :none, :none]
      assert state.alerting
      assert state.first_failure_at == @now
      assert state.last_failure == %{peer: "fdaa::1:2", error: "timeout"}
    end

    test "re-triggers every five failures while alerting" do
      {_state, actions} = apply_results(%State{}, List.duplicate(@failure, 14))

      triggers = for {:trigger, i} <- Enum.with_index(actions, 1), do: i
      assert triggers == [4, 9, 14]
    end

    test "a success resets the failure streak" do
      results = [@failure, @failure, @failure, {:ok, @peer}, @failure, @failure, @failure]
      {state, actions} = apply_results(%State{}, results)

      refute :trigger in actions
      refute state.alerting
    end

    test "resolves after three successes in a row" do
      results = List.duplicate(@failure, 4) ++ List.duplicate({:ok, @peer}, 3)
      {state, actions} = apply_results(%State{}, results)

      assert actions == [:none, :none, :none, :trigger, :none, :none, :resolve]
      refute state.alerting
      assert state.last_failure == nil
    end

    test "skips don't count either way" do
      results = [@failure, @failure, @failure, :skip, :skip, @failure]
      {_state, actions} = apply_results(%State{}, results)

      assert List.last(actions) == :trigger
    end
  end

  describe "select_peers/3" do
    test "excludes our own address" do
      assert SixPNProbe.select_peers([@self, @peer], [], @self) == {:ok, [@peer]}
    end

    test "fails on any IPv4 answer" do
      assert {:error, "got IPv4 address 10.0.0.1"} =
               SixPNProbe.select_peers([@peer], [{10, 0, 0, 1}], @self)
    end
  end
end
