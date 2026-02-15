defmodule Elektrine.Discord do
  @moduledoc """
  Discord integration using Lanyard API for real-time status.
  """

  require Logger

  @lanyard_base_url "https://api.lanyard.rest/v1/users/"

  @doc """
  Gets Discord presence data for a user ID.
  Returns nil if user is not found or offline.
  """
  def get_user_presence(discord_id) when is_binary(discord_id) do
    request = Finch.build(:get, "#{@lanyard_base_url}#{discord_id}")

    case Finch.request(request, Elektrine.Finch, receive_timeout: 5000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"success" => true, "data" => data}} ->
            parse_discord_data(data)

          {:ok, %{"success" => false, "error" => error}} ->
            Logger.warning("Lanyard API error for #{discord_id}: #{error}")
            nil

          {:error, decode_error} ->
            Logger.warning(
              "Failed to parse Lanyard response for #{discord_id}: #{inspect(decode_error)}"
            )

            nil
        end

      {:ok, %Finch.Response{status: 404}} ->
        nil

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("Lanyard API returned status #{status} for #{discord_id}. Body: #{body}")
        nil

      {:error, reason} ->
        Logger.error("Failed to fetch Discord data for #{discord_id}: #{inspect(reason)}")
        nil
    end
  end

  def get_user_presence(_), do: nil

  # Parse Lanyard API response into useful data
  defp parse_discord_data(data) do
    discord_user = data["discord_user"] || %{}

    # Use global_name or display_name if available, fallback to username
    display_name =
      discord_user["global_name"] ||
        discord_user["display_name"] ||
        discord_user["username"] ||
        "Unknown"

    %{
      username: display_name,
      discriminator: discord_user["discriminator"],
      avatar: get_avatar_url(discord_user),
      # "online", "idle", "dnd", "offline"
      status: data["discord_status"],
      activities: parse_activities(data["activities"] || []),
      spotify: parse_spotify(data["spotify"]),
      custom_status: get_custom_status(data["activities"] || [])
    }
  end

  # Get Discord avatar URL
  defp get_avatar_url(%{"id" => user_id, "avatar" => nil}), do: get_default_avatar(user_id)

  defp get_avatar_url(%{"id" => user_id, "avatar" => avatar_hash}) when is_binary(avatar_hash) do
    ext = if String.starts_with?(avatar_hash, "a_"), do: "gif", else: "webp"
    "https://cdn.discordapp.com/avatars/#{user_id}/#{avatar_hash}.#{ext}?size=128"
  end

  # Fallback for missing/invalid avatar
  defp get_avatar_url(%{"id" => user_id}), do: get_default_avatar(user_id)
  defp get_avatar_url(_), do: "https://cdn.discordapp.com/embed/avatars/0.png"

  defp get_default_avatar(user_id) when is_binary(user_id) do
    # Discord's default avatar logic
    id_int = String.to_integer(user_id)
    discriminator = rem(id_int, 5)
    "https://cdn.discordapp.com/embed/avatars/#{discriminator}.png"
  end

  defp get_default_avatar(_), do: "https://cdn.discordapp.com/embed/avatars/0.png"

  # Parse Discord activities (games, apps, etc.)
  defp parse_activities(activities) do
    activities
    # Exclude custom status
    |> Enum.reject(&(&1["type"] == 4))
    |> Enum.map(fn activity ->
      %{
        name: activity["name"],
        # 0: Playing, 1: Streaming, 2: Listening, 3: Watching
        type: activity["type"],
        details: activity["details"],
        state: activity["state"]
      }
    end)
  end

  # Parse Spotify data if listening
  defp parse_spotify(nil), do: nil

  defp parse_spotify(spotify) do
    %{
      song: spotify["song"],
      artist: spotify["artist"],
      album: spotify["album"],
      album_art: List.first(spotify["album_art_url"] || []),
      track_id: spotify["track_id"]
    }
  end

  # Get custom status message
  defp get_custom_status(activities) do
    activities
    # Custom status type
    |> Enum.find(&(&1["type"] == 4))
    |> case do
      nil -> nil
      activity -> activity["state"]
    end
  end

  @doc """
  Gets a formatted status string for display.
  """
  def format_status(nil), do: "Offline"
  def format_status(%{status: "online"}), do: "Online"
  def format_status(%{status: "idle"}), do: "Away"
  def format_status(%{status: "dnd"}), do: "Do Not Disturb"
  def format_status(%{status: "offline"}), do: "Offline"
  def format_status(_), do: "Unknown"
end
