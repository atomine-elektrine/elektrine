defmodule Elektrine.ActivityPub.MRF.RemoteReportPolicy do
  @moduledoc """
  Filters low-quality remote Flag activities.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"type" => "Flag"} = activity) do
    config = Application.get_env(:elektrine, :mrf_remote_report, [])

    cond do
      Utils.local_actor?(activity["actor"]) ->
        {:ok, activity}

      Keyword.get(config, :reject_all, false) ->
        {:reject, "[RemoteReportPolicy] remote reports rejected"}

      Keyword.get(config, :reject_anonymous, false) and anonymous_actor?(activity["actor"]) ->
        {:reject, "[RemoteReportPolicy] anonymous remote report rejected"}

      Keyword.get(config, :reject_third_party, false) and third_party_report?(activity) ->
        {:reject, "[RemoteReportPolicy] third-party report rejected"}

      Keyword.get(config, :reject_empty_message, false) and empty_content?(activity) ->
        {:reject, "[RemoteReportPolicy] empty remote report rejected"}

      true ->
        {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok,
     %{mrf_remote_report: Application.get_env(:elektrine, :mrf_remote_report, []) |> Map.new()}}
  end

  defp anonymous_actor?(actor) when is_binary(actor) do
    URI.parse(actor).path == "/actor"
  end

  defp anonymous_actor?(_), do: false

  defp third_party_report?(%{"object" => [reported | _]}) when is_binary(reported),
    do: not Utils.local_actor?(reported)

  defp third_party_report?(%{"object" => reported}) when is_binary(reported),
    do: not Utils.local_actor?(reported)

  defp third_party_report?(_), do: false

  defp empty_content?(%{"content" => content}) when is_binary(content),
    do: String.trim(Utils.strip_html(content)) == ""

  defp empty_content?(_), do: true
end
