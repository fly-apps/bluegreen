defmodule BluegreenWeb.MetricsTest do
  @moduledoc """
  Fly's managed Prometheus scrapes this endpoint, so a route that stops serving
  the gauge takes the squawk check down with it — silently, since an absent
  series reads the same as a healthy region.
  """
  use BluegreenWeb.ConnCase, async: false

  alias Bluegreen.SixPNProbe.PromExPlugin

  test "GET /metrics serves the 6PN failure gauge", %{conn: conn} do
    PromExPlugin.execute_probe_metrics(4)

    body = conn |> get("/metrics") |> response(200)

    assert body =~ "fly_flybg_6pn_consecutive_failures 4"
  end
end
