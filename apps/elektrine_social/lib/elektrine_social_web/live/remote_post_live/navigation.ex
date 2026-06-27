defmodule ElektrineSocialWeb.RemotePostLive.Navigation do
  @moduledoc false

  alias Elektrine.Messaging
  alias Elektrine.Paths
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  def normalize_post_id(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        case socket.assigns[:local_message] do
          %{id: ^id, activitypub_id: activitypub_id}
          when is_binary(activitypub_id) and activitypub_id != "" ->
            activitypub_id

          _ ->
            Integer.to_string(id)
        end

      :error ->
        to_string(decoded_value)
    end
  end

  def post_path(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        post =
          case socket.assigns[:local_message] do
            %Message{id: ^id} = message ->
              Repo.preload(message, [:conversation])

            _ ->
              fetch_post_for_navigation(id)
          end

        Paths.post_path(post || id)

      :error ->
        Paths.post_path_or_external(normalize_post_id(socket, decoded_value))
    end
  end

  def navigate_to_remote_post_ref(socket, value) do
    navigate_id = normalize_post_id(socket, value)

    case parse_local_message_id(navigate_id) do
      {:ok, local_id} ->
        Phoenix.LiveView.push_navigate(socket, to: Paths.remote_post_path(local_id))

      :error ->
        ElektrineWeb.PostNavigation.navigate(socket, navigate_id)
    end
  end

  def canonical_remote_post_path(ref), do: remote_detail_post_path(ref)

  def remote_detail_post_path(ref), do: Paths.remote_post_path(ref)

  def current_post_path_from_uri(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    case {parsed.path, parsed.query} do
      {path, nil} when is_binary(path) -> path
      {path, query} when is_binary(path) and is_binary(query) -> path <> "?" <> query
      _ -> nil
    end
  end

  def current_post_path_from_uri(_), do: nil

  def parse_local_message_id(value) when is_integer(value), do: {:ok, value}

  def parse_local_message_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  def parse_local_message_id(_), do: :error

  def decode_post_ref(value) when is_binary(value) do
    trimmed = String.trim(value)

    try do
      URI.decode_www_form(trimmed)
    rescue
      ArgumentError -> trimmed
    end
  end

  def decode_post_ref(value), do: value

  defp fetch_post_for_navigation(id) when is_integer(id) do
    case Messaging.get_message(id) do
      %Message{} = post -> Repo.preload(post, [:conversation])
      _ -> nil
    end
  end
end
