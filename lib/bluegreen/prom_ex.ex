defmodule Bluegreen.PromEx do
  @moduledoc """
  Exports the metrics that alerting reads.

  flybg does not page anyone itself. It publishes the 6PN probe's failure
  streak, Fly's managed Prometheus scrapes `/metrics` (see `[[metrics]]` in
  fly.toml), and the alert lives in superfly/squawk-checks as
  `flybg_6pn_unreachable`. Squawk owns the threshold, the runbook, the Slack
  and incident.io delivery, and the silencing.

  Only our own plugin is enabled: `/metrics` is served off the public
  endpoint, so there is no reason to publish BEAM internals with it.
  """
  use PromEx, otp_app: :bluegreen

  @impl true
  def plugins, do: [Bluegreen.SixPNProbe.PromExPlugin]

  @impl true
  def dashboards, do: []
end
