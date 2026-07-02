defmodule Elektrine.ActivityPub.MRF.ForceBotUnlistedPolicy do
  @moduledoc """
  Converts public posts from likely bot actors to unlisted.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"type" => "Create", "actor" => actor, "object" => object} = activity)
      when is_binary(actor) and is_map(object) do
    if Utils.visibility(activity) == "public" and bot_actor?(actor) do
      {:ok, Utils.delist(activity)}
    else
      {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{mrf_force_bot_unlisted: true}}

  defp bot_actor?(actor_uri) do
    case ActivityPub.get_actor_by_uri(actor_uri) do
      %Actor{actor_type: type} when type in ["Application", "Service"] ->
        true

      %Actor{username: username} when is_binary(username) ->
        bot_username?(username)

      _ ->
        actor_uri
        |> URI.parse()
        |> Map.get(:path)
        |> to_string()
        |> Path.basename()
        |> bot_username?()
    end
  end

  defp bot_username?(username) when is_binary(username) do
    Regex.match?(~r/(^|[-_.])(bot|ebooks)($|[-_.])/i, username) or
      Regex.match?(~r/(bot|ebooks)@/i, username)
  end

  defp bot_username?(_), do: false
end
