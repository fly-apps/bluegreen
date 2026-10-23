defmodule Bluegreen.SixPNProbe.PromExPlugin do
  @moduledoc """
  Exposes the 6PN probe's failure streak.

  Emits:
  - `fly_flybg_6pn_consecutive_failures` — probes in a row in which this
    machine could not reach a peer over 6PN.

  An event metric rather than a polling one: only the probe knows when it has
  a fresh answer, and polling a gauge off its own schedule would report a
  stale streak as a current one.

  The gauge carries no labels of its own. Fly's managed Prometheus stamps
  `app`, `instance`, `region` and `host` onto everything it scrapes, which is
  exactly the set the alert needs.
  """
  use PromEx.Plugin

  @event [:bluegreen, :six_pn, :probe]

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :bluegreen_six_pn_metrics,
        [
          last_value(
            [:fly, :flybg, :"6pn", :consecutive_failures],
            event_name: @event,
            description: "Probes in a row where this machine could not reach a peer over 6PN.",
            measurement: :consecutive_failures
          )
        ]
      )
    ]
  end

  @doc false
  def execute_probe_metrics(consecutive_failures) do
    :telemetry.execute(@event, %{consecutive_failures: consecutive_failures}, %{})
  end
end
