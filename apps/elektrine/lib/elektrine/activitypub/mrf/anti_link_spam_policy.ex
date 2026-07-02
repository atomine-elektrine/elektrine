defmodule Elektrine.ActivityPub.MRF.AntiLinkSpamPolicy do
  @moduledoc """
  Rejects link posts from unknown or very new remote actors.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  import Ecto.Query

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.MRF.Utils
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  @impl true
  def filter(%{"type" => "Create", "actor" => actor, "object" => object} = activity)
      when is_binary(actor) and is_map(object) do
    if Utils.local_actor?(actor) or not contains_external_links?(object) do
      {:ok, activity}
    else
      case remote_actor_reputation(actor) do
        :trusted -> {:ok, activity}
        :unknown -> {:reject, "[AntiLinkSpamPolicy] unknown remote actor posted links"}
        :new -> {:reject, "[AntiLinkSpamPolicy] new remote actor posted links"}
      end
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok, %{mrf_anti_link_spam: Map.new(config())}}
  end

  defp contains_external_links?(object) do
    content = Map.get(object, "content", "")

    hrefs =
      Regex.scan(~r/<a[^>]+href=["']([^"']+)["']/i, content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&mention_or_hashtag_link?/1)

    plain_urls =
      content
      |> Utils.strip_html()
      |> then(&Regex.scan(~r/https?:\/\/[^\s<>"']+/i, &1))
      |> List.flatten()

    hrefs != [] or plain_urls != []
  end

  defp mention_or_hashtag_link?(href) when is_binary(href) do
    String.contains?(href, ["/tags/", "/tag/", "/users/", "/@"]) or String.starts_with?(href, "#")
  end

  defp mention_or_hashtag_link?(_), do: false

  defp remote_actor_reputation(actor_uri) do
    case ActivityPub.get_actor_by_uri(actor_uri) do
      nil ->
        :unknown

      %Actor{} = actor ->
        cond do
          cached_post_count(actor.id) > 0 -> :trusted
          old_enough?(actor) -> :trusted
          true -> :new
        end
    end
  end

  defp cached_post_count(actor_id) do
    Repo.one(
      from m in Message,
        where: m.remote_actor_id == ^actor_id and is_nil(m.deleted_at),
        select: count(m.id)
    ) || 0
  end

  defp old_enough?(%Actor{inserted_at: inserted_at}) do
    min_age_seconds = Keyword.get(config(), :min_actor_age_seconds, 30 * 60)
    DateTime.diff(DateTime.utc_now(), to_datetime(inserted_at), :second) >= min_age_seconds
  end

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")
  defp to_datetime(_), do: DateTime.utc_now()

  defp config, do: Application.get_env(:elektrine, :mrf_anti_link_spam, [])
end
