defmodule Elektrine.ActivityPub.LocalReferences do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Activity
  alias Elektrine.Domains
  alias Elektrine.Repo

  @public_audience_uri "https://www.w3.org/ns/activitystreams#Public"

  def actor_prefixes do
    domains = Domains.activitypub_domains()

    urls =
      [instance_url()] ++
        Enum.flat_map(domains, fn domain -> ["https://#{domain}", "http://#{domain}"] end)

    urls
    |> Enum.uniq()
    |> Enum.map(&(String.trim_trailing(&1, "/") <> "/users/"))
  end

  def local_username_from_uri(uri) when is_binary(uri) do
    normalized_uri = String.trim(uri)

    if Elektrine.Strings.present?(normalized_uri) do
      case URI.parse(normalized_uri) do
        %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
          if Domains.local_activitypub_domain?(String.downcase(host)) do
            username_from_local_path(path)
          else
            {:error, :not_local}
          end

        _ ->
          {:error, :invalid_uri}
      end
    else
      {:error, :invalid_uri}
    end
  end

  def local_username_from_uri(_), do: {:error, :invalid_uri}

  def resolve_target_user(activity) when is_map(activity) do
    case resolve_target_user_id(activity) do
      user_id when is_integer(user_id) -> Repo.get(User, user_id)
      _ -> nil
    end
  end

  def resolve_target_user(_), do: nil

  def resolve_target_user_id(activity) when is_map(activity) do
    direct_ref =
      activity
      |> candidate_target_refs()
      |> Enum.find_value(&target_user_id_from_ref/1)

    direct_ref || inferred_recipient_user_id(activity)
  end

  def resolve_target_user_id(_), do: nil

  defp username_from_local_path(path) do
    case extract_local_identifier_from_path(path) do
      nil ->
        {:error, :not_local}

      identifier ->
        case Elektrine.Accounts.get_user_by_activitypub_identifier(identifier) do
          %User{username: username} -> {:ok, username}
          _ -> {:ok, actor_identifier(identifier)}
        end
    end
  end

  defp extract_local_identifier_from_path(path) when is_binary(path) do
    case path |> String.trim_leading("/") |> String.split("/", trim: true) do
      ["users", identifier | _] ->
        if Elektrine.Strings.present?(identifier), do: identifier, else: nil

      [<<"@", identifier::binary>> | _] ->
        if Elektrine.Strings.present?(identifier), do: identifier, else: nil

      _ ->
        nil
    end
  end

  defp inferred_recipient_user_id(%{"type" => type} = activity)
       when type in ["Follow", "Accept", "Reject", "Block", "Flag", "Move"] do
    single_recipient_user_id(activity)
  end

  defp inferred_recipient_user_id(_), do: nil

  defp candidate_target_refs(activity) when is_map(activity) do
    []
    |> add_candidate_ref(Map.get(activity, "object"))
    |> add_candidate_ref(Map.get(activity, "target"))
    |> Enum.reverse()
  end

  defp add_candidate_ref(acc, nil), do: acc
  defp add_candidate_ref(acc, value) when is_binary(value), do: [value | acc]

  defp add_candidate_ref(acc, values) when is_list(values) do
    Enum.reduce(values, acc, fn value, nested_acc -> add_candidate_ref(nested_acc, value) end)
  end

  defp add_candidate_ref(acc, %{} = value) do
    acc
    |> add_candidate_ref(Map.get(value, "id"))
    |> add_candidate_ref(Map.get(value, "object"))
    |> add_candidate_ref(Map.get(value, "target"))
    |> add_candidate_ref(Map.get(value, "inReplyTo"))
    |> add_candidate_ref(Map.get(value, "url"))
    |> add_candidate_ref(Map.get(value, "href"))
  end

  defp add_candidate_ref(acc, _value), do: acc

  defp single_recipient_user_id(activity) do
    recipient_ids =
      activity
      |> recipient_refs()
      |> Enum.map(&local_user_id_from_uri/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case recipient_ids do
      [user_id] -> user_id
      _ -> nil
    end
  end

  defp recipient_refs(activity) when is_map(activity) do
    activity_object =
      case Map.get(activity, "object") do
        %{} = object -> object
        _ -> %{}
      end

    mention_refs =
      if public_activity?(activity, activity_object) do
        []
      else
        mention_hrefs(activity_object)
      end

    [
      Map.get(activity, "to"),
      Map.get(activity, "cc"),
      Map.get(activity, "audience"),
      Map.get(activity, "target"),
      Map.get(activity_object, "to"),
      Map.get(activity_object, "cc"),
      Map.get(activity_object, "audience"),
      mention_refs
    ]
    |> Enum.flat_map(&recipient_values/1)
  end

  defp recipient_refs(_), do: []

  defp recipient_values(nil), do: []
  defp recipient_values(value) when is_binary(value), do: [value]

  defp recipient_values(values) when is_list(values) do
    Enum.flat_map(values, &recipient_values/1)
  end

  defp recipient_values(%{} = value) do
    [Map.get(value, "id"), Map.get(value, "href"), Map.get(value, "url")]
    |> Enum.map(&Elektrine.Strings.present/1)
    |> Enum.reject(&is_nil/1)
  end

  defp recipient_values(_), do: []

  defp mention_hrefs(%{"tag" => tags}) when is_list(tags) do
    tags
    |> Enum.filter(&(Map.get(&1, "type") == "Mention"))
    |> Enum.map(&Map.get(&1, "href"))
    |> Enum.map(&Elektrine.Strings.present/1)
    |> Enum.reject(&is_nil/1)
  end

  defp mention_hrefs(_), do: []

  defp public_activity?(activity, activity_object)
       when is_map(activity) and is_map(activity_object) do
    [
      Map.get(activity, "to"),
      Map.get(activity, "cc"),
      Map.get(activity, "audience"),
      Map.get(activity_object, "to"),
      Map.get(activity_object, "cc"),
      Map.get(activity_object, "audience")
    ]
    |> Enum.flat_map(&recipient_values/1)
    |> Enum.any?(&(&1 == @public_audience_uri))
  end

  defp public_activity?(_, _), do: false

  defp target_user_id_from_ref(ref) when is_binary(ref) do
    local_user_id_from_activity(ref) ||
      local_user_id_from_uri(ref) ||
      local_user_id_from_message(ref)
  end

  defp target_user_id_from_ref(_), do: nil

  defp local_user_id_from_activity(activity_id) when is_binary(activity_id) do
    case get_activity_by_id(activity_id) do
      %Activity{internal_user_id: user_id} when is_integer(user_id) -> user_id
      _ -> nil
    end
  end

  defp local_user_id_from_uri(uri) when is_binary(uri) do
    case local_username_from_uri(uri) do
      {:ok, username} ->
        case Elektrine.Accounts.get_user_by_username(username) do
          %User{id: user_id} -> user_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp local_user_id_from_uri(_), do: nil

  defp local_user_id_from_message(ref) when is_binary(ref) do
    case Elektrine.Messaging.get_message_by_activitypub_ref(ref) do
      %{sender_id: user_id} when is_integer(user_id) -> user_id
      _ -> nil
    end
  end

  defp get_activity_by_id(activity_id) do
    from(a in Activity, where: a.activity_id == ^activity_id)
    |> Repo.one()
  end

  defp instance_url do
    Domains.inferred_base_url_for_domain(Domains.instance_domain())
  end

  defp actor_identifier(%User{handle: handle, username: username}) do
    if Elektrine.Strings.present?(handle), do: handle, else: username
  end

  defp actor_identifier(%{handle: handle, username: username}) do
    if Elektrine.Strings.present?(handle), do: handle, else: username
  end

  defp actor_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp actor_identifier(_), do: nil
end
