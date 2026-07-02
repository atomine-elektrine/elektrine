defmodule Elektrine.ActivityPub.MRF.AntiFollowbotPolicy do
  @moduledoc """
  Rejects obvious remote follow-bot accounts unless the local target follows them.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles

  @impl true
  def filter(%{"type" => "Follow", "actor" => actor_ref, "object" => object_ref} = activity) do
    with actor_uri when is_binary(actor_uri) <- actor_uri(actor_ref),
         %Actor{} = actor <- ActivityPub.get_actor_by_uri(actor_uri),
         true <- followbot?(actor),
         {:ok, target_user} <- local_target_user(object_ref),
         false <- Profiles.following_remote_actor_by_identity?(target_user.id, actor) do
      {:reject, "[AntiFollowbotPolicy] rejected follow-bot actor #{actor_uri}"}
    else
      _ -> {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{mrf_anti_followbot: true}}

  defp followbot?(%Actor{} = actor), do: followbot_score(actor) >= 0.8

  defp followbot_score(%Actor{} = actor) do
    nickname_score(actor) + display_name_score(actor) + actor_type_score(actor)
  end

  defp nickname_score(%Actor{username: username, domain: domain})
       when is_binary(username) and is_binary(domain) do
    score_nickname(String.downcase("#{username}@#{domain}"))
  end

  defp nickname_score(_actor), do: 0.0

  defp score_nickname("followbot@" <> _), do: 1.0
  defp score_nickname("federationbot@" <> _), do: 1.0
  defp score_nickname("federation_bot@" <> _), do: 1.0
  defp score_nickname(_nickname), do: 0.0

  defp display_name_score(%Actor{display_name: display_name}) when is_binary(display_name) do
    display_name
    |> String.downcase()
    |> String.trim()
    |> score_display_name()
  end

  defp display_name_score(_actor), do: 0.0

  defp score_display_name("federation bot"), do: 1.0
  defp score_display_name("federationbot"), do: 1.0
  defp score_display_name("fedibot"), do: 1.0
  defp score_display_name(_display_name), do: 0.0

  defp actor_type_score(%Actor{actor_type: actor_type})
       when actor_type in ["Service", "Application"],
       do: 1.0

  defp actor_type_score(_actor), do: 0.0

  defp local_target_user(object_ref) do
    case object_ref |> actor_uri() |> ActivityPub.local_username_from_uri() do
      {:ok, username} when is_binary(username) ->
        case Accounts.get_user_by_activitypub_identifier(username) do
          nil -> :error
          user -> {:ok, user}
        end

      _ ->
        :error
    end
  end

  defp actor_uri(uri) when is_binary(uri), do: uri
  defp actor_uri(%{"id" => uri}) when is_binary(uri), do: uri
  defp actor_uri(_), do: nil
end
