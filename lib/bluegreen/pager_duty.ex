defmodule Bluegreen.PagerDuty do
  @moduledoc """
  Thin client for the PagerDuty Events API v2, the same as `ATC.PagerDuty` in
  air-traffic. A stable `dedup_key` folds repeated triggers into one alert, and
  `resolve/1` with the same key closes it.

  No-ops with a log line when `PAGERDUTY_ROUTING_KEY` is unset, so it is safe to
  call in dev/test without a real integration key.
  """
  require Logger

  @url "https://events.pagerduty.com/v2/enqueue"

  @doc "Open (or re-assert) an alert for `dedup_key`."
  def trigger(dedup_key, payload), do: enqueue(dedup_key, "trigger", payload)

  @doc "Resolve the alert for `dedup_key`, if one is open."
  def resolve(dedup_key), do: enqueue(dedup_key, "resolve", %{})

  def enqueue(dedup_key, event_action, payload) do
    case routing_key() do
      nil ->
        Logger.warning(
          "PAGERDUTY_ROUTING_KEY not set, skipping PagerDuty #{event_action} for #{dedup_key}"
        )

        :ok

      key ->
        body =
          payload
          |> Map.merge(%{
            event_action: event_action,
            dedup_key: dedup_key,
            routing_key: key
          })
          |> Jason.encode!()

        :post
        |> Finch.build(@url, [{"content-type", "application/json"}], body)
        # Short enough to fit in the machine's kill timeout when the probe
        # resolves its alert on shutdown.
        |> Finch.request(Bluegreen.Finch, receive_timeout: 3_000)
        |> handle_response(event_action, dedup_key)
    end
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, event_action, dedup_key)
       when status in 200..299 do
    Logger.info("PagerDuty #{event_action} accepted for #{dedup_key}")
    :ok
  end

  defp handle_response(
         {:ok, %Finch.Response{status: status, body: body}},
         event_action,
         dedup_key
       ) do
    Logger.error("PagerDuty #{event_action} failed for #{dedup_key}: HTTP #{status} #{body}")
    {:error, {:http_status, status}}
  end

  defp handle_response({:error, reason} = error, event_action, dedup_key) do
    Logger.error("PagerDuty #{event_action} request error for #{dedup_key}: #{inspect(reason)}")
    error
  end

  defp routing_key do
    :bluegreen
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:routing_key)
  end
end
