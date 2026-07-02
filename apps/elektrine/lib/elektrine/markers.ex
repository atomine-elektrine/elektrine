defmodule Elektrine.Markers do
  @moduledoc """
  Stores durable client read positions for timelines and notifications.
  """

  import Ecto.Query

  alias Elektrine.Markers.Marker
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo

  @type marker_attrs :: %{required(String.t()) => map()} | %{required(atom()) => map()}

  @doc """
  Returns markers for the requested timelines.
  """
  def list_markers(user_id, timelines) do
    timelines = normalize_timelines(timelines)

    from(marker in Marker,
      where: marker.user_id == ^user_id and marker.timeline in ^timelines
    )
    |> Repo.all()
    |> Enum.map(&with_unread_count/1)
    |> Map.new(&{&1.timeline, &1})
  end

  @doc """
  Upserts markers from a Mastodon/Pleroma-style payload.

  Expected shape:

      %{"home" => %{"last_read_id" => "123"}}
  """
  @spec upsert_markers(pos_integer(), marker_attrs()) ::
          {:ok, %{String.t() => Marker.t()}} | {:error, Ecto.Changeset.t()}
  def upsert_markers(user_id, attrs) when is_map(attrs) do
    entries = normalize_marker_attrs(attrs)

    Repo.transaction(fn ->
      Enum.reduce_while(entries, %{}, fn {timeline, marker_attrs}, acc ->
        case upsert_marker(user_id, timeline, marker_attrs) do
          {:ok, marker} ->
            marker = with_unread_count(marker)
            {:cont, Map.put(acc, marker.timeline, marker)}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end)
  end

  def format_marker(marker) do
    %{
      last_read_id: marker.last_read_id,
      unread_count: marker.unread_count || 0,
      version: marker.version,
      updated_at: marker.updated_at
    }
  end

  defp with_unread_count(%Marker{timeline: "notifications", user_id: user_id} = marker)
       when is_integer(user_id) do
    %{marker | unread_count: notification_unread_count(user_id)}
  end

  defp with_unread_count(%Marker{} = marker), do: %{marker | unread_count: 0}

  defp notification_unread_count(user_id) do
    count =
      from(n in Notification,
        where: n.user_id == ^user_id and is_nil(n.read_at) and is_nil(n.dismissed_at),
        select: count(n.id)
      )
      |> Repo.one()

    count || 0
  end

  defp upsert_marker(user_id, timeline, attrs) do
    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:timeline, timeline)

    case Repo.get_by(Marker, user_id: user_id, timeline: timeline) do
      nil ->
        %Marker{}
        |> Marker.changeset(Map.put(attrs, :version, 0))
        |> Repo.insert()

      marker ->
        marker
        |> Marker.changeset(Map.put(attrs, :version, marker.version + 1))
        |> Repo.update()
    end
  end

  defp normalize_timelines(nil), do: []
  defp normalize_timelines(timeline) when is_binary(timeline), do: [timeline]

  defp normalize_timelines(timelines) when is_list(timelines) do
    timelines
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_timelines(_), do: []

  defp normalize_marker_attrs(attrs) do
    attrs
    |> Enum.flat_map(fn {timeline, value} ->
      with true <- valid_timeline_key?(timeline),
           %{} = marker_attrs <- normalize_marker_value(value),
           last_read_id when is_binary(last_read_id) <- marker_attrs[:last_read_id] do
        [{to_string(timeline), %{last_read_id: last_read_id}}]
      else
        _ -> []
      end
    end)
  end

  defp valid_timeline_key?(key) when is_binary(key), do: true
  defp valid_timeline_key?(key) when is_atom(key), do: true
  defp valid_timeline_key?(_), do: false

  defp normalize_marker_value(value) when is_map(value) do
    last_read_id = value[:last_read_id] || value["last_read_id"]

    if is_binary(last_read_id) do
      %{last_read_id: last_read_id}
    else
      nil
    end
  end

  defp normalize_marker_value(_), do: nil
end
