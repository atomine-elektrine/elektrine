defmodule ElektrineSocialWeb.RemotePostLive.Polls do
  @moduledoc false

  def build_poll_fields_from_message(nil), do: %{}

  def build_poll_fields_from_message(message) do
    cond do
      message.post_type != "poll" ->
        %{}

      !Ecto.assoc_loaded?(message.poll) || is_nil(message.poll) ->
        %{}

      true ->
        poll = message.poll

        options =
          if Ecto.assoc_loaded?(poll.options) do
            Enum.map(poll.options, fn option ->
              %{
                "type" => "Note",
                "name" => option.option_text,
                "replies" => %{
                  "type" => "Collection",
                  "totalItems" => option.vote_count || 0
                }
              }
            end)
          else
            []
          end

        if options == [] do
          %{}
        else
          poll_key = if poll.allow_multiple, do: "anyOf", else: "oneOf"

          %{
            "type" => "Question",
            poll_key => options,
            "votersCount" => poll.voters_count || poll.total_votes || 0
          }
          |> maybe_add_poll_close_time(poll.closes_at)
        end
    end
  end

  def merge_local_poll_data(post_object, local_message) do
    if post_has_poll_data?(post_object) do
      post_object
    else
      Map.merge(post_object, build_poll_fields_from_message(local_message))
    end
  end

  defp maybe_add_poll_close_time(poll_fields, %DateTime{} = closes_at) do
    timestamp = DateTime.to_iso8601(closes_at)

    poll_fields
    |> Map.put("endTime", timestamp)
    |> Map.put("closed", timestamp)
  end

  defp maybe_add_poll_close_time(poll_fields, %NaiveDateTime{} = closes_at) do
    timestamp = closes_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

    poll_fields
    |> Map.put("endTime", timestamp)
    |> Map.put("closed", timestamp)
  end

  defp maybe_add_poll_close_time(poll_fields, _), do: poll_fields

  defp post_has_poll_data?(post_object) when is_map(post_object) do
    post_object["type"] == "Question" ||
      is_list(post_object["oneOf"]) ||
      is_list(post_object["anyOf"])
  end

  defp post_has_poll_data?(_), do: false
end
