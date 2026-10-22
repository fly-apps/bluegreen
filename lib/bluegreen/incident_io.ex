defmodule Bluegreen.IncidentIo do
  @moduledoc """
  Thin client for the incident.io HTTP alert source, the same as
  `ATC.IncidentIo` in air-traffic and `Hawk.IncidentIo` in hawk. A stable
  `deduplication_key` folds repeated `firing` events into one alert, and a
  `resolved` event with the same key closes it.

  Everything routable — severity, region, source — has to live under
  `metadata`. incident.io alert attribute expressions cannot read the top
  level of the payload, so a severity left there is invisible to alert routes.

  No-ops with a log line when the alert source is unconfigured, so it is safe
  to call in dev/test without real credentials.
  """
  require Logger

  @url "https://api.incident.io/v2/alert_events/http"

  @doc "Open (or re-assert) the alert for `dedup_key`."
  def trigger(dedup_key, event), do: send_event(dedup_key, "firing", event)

  @doc """
  Resolve the alert for `dedup_key`, if one is open.

  Takes the same event as `trigger/2`, because incident.io requires a `title`
  on every event — unlike PagerDuty, a resolve is not just a key.
  """
  def resolve(dedup_key, event), do: send_event(dedup_key, "resolved", event)

  def send_event(dedup_key, status, event) do
    case {alert_source_config_id(), token()} do
      {id, token} when is_binary(id) and is_binary(token) ->
        body = dedup_key |> alert_event(status, event) |> Jason.encode!()

        :post
        |> Finch.build(
          "#{@url}/#{id}",
          [{"content-type", "application/json"}, {"authorization", "Bearer #{token}"}],
          body
        )
        |> Finch.request(Bluegreen.Finch, receive_timeout: 3_000)
        |> handle_response(status, dedup_key)

      _ ->
        Logger.warning(
          "incident.io alert source not configured, skipping #{status} event for #{dedup_key}"
        )

        :ok
    end
  end

  @doc false
  # Public so the payload shape can be asserted without an HTTP call.
  def alert_event(dedup_key, status, event) do
    %{
      title: Map.fetch!(event, :title),
      status: status,
      deduplication_key: dedup_key,
      description: event[:description],
      source_url: event[:source_url],
      metadata: reject_nils(event[:metadata] || %{})
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp reject_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp handle_response({:ok, %Finch.Response{status: http_status}}, status, dedup_key)
       when http_status in 200..299 do
    Logger.info("incident.io #{status} event accepted for #{dedup_key}")
    :ok
  end

  # Resolving an alert incident.io never saw is not a failure, and with a
  # per-region dedup key a fresh machine resolves keys it never opened. 422 is
  # deliberately not in this list: that is a validation error and has to
  # surface.
  defp handle_response({:ok, %Finch.Response{status: http_status}}, "resolved", dedup_key)
       when http_status in [404, 410] do
    Logger.info("incident.io had nothing to resolve for #{dedup_key}")
    :ok
  end

  defp handle_response(
         {:ok, %Finch.Response{status: http_status, body: body}},
         status,
         dedup_key
       ) do
    Logger.error(
      "incident.io #{status} event failed for #{dedup_key}: HTTP #{http_status} #{body}"
    )

    {:error, {:http_status, http_status}}
  end

  defp handle_response({:error, reason} = error, status, dedup_key) do
    Logger.error("incident.io #{status} event request error for #{dedup_key}: #{inspect(reason)}")

    error
  end

  defp token, do: config()[:token]
  defp alert_source_config_id, do: config()[:alert_source_config_id]
  defp config, do: Application.get_env(:bluegreen, __MODULE__, [])
end
