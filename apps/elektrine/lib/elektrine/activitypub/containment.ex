defmodule Elektrine.ActivityPub.Containment do
  @moduledoc """
  Origin containment checks for remote ActivityPub payloads.

  These checks prevent remote servers from smuggling objects that claim to be
  authored by another host or by this instance.
  """

  alias Elektrine.ActivityPub

  @actor_types ["Person", "Group", "Application", "Service", "Organization"]

  def validate_fetch(uri, object) when is_binary(uri) and is_map(object) do
    with :ok <- contain_local_fetch(uri),
         :ok <- contain_fetch_origin(uri, object) do
      contain_child(object)
    end
  end

  def validate_fetch(_uri, _object), do: :ok

  def validate_activity(%{"type" => "Create", "object" => object} = activity)
      when is_map(object) do
    with :ok <- contain_origin(activity),
         :ok <- contain_origin(object) do
      contain_child(activity)
    end
  end

  def validate_activity(%{"type" => "Update", "object" => object} = activity)
      when is_map(object) do
    with :ok <- contain_origin(activity),
         :ok <- contain_origin(object) do
      contain_child(activity)
    end
  end

  def validate_activity(%{"type" => type} = activity) when type in @actor_types do
    contain_origin_from_id(actor_uri(activity), activity)
  end

  def validate_activity(%{"type" => _type} = activity), do: contain_origin(activity)
  def validate_activity(_), do: {:error, :origin_containment_failed}

  def contain_local_fetch(id) when is_binary(id) do
    with %URI{host: host} when is_binary(host) <- URI.parse(id),
         local when is_binary(local) <- ActivityPub.instance_domain(),
         true <- String.downcase(host) == String.downcase(local) do
      {:error, :local_fetch_containment_failed}
    else
      _ -> :ok
    end
  end

  def contain_local_fetch(_), do: :ok

  def contain_origin(%{"id" => id} = object) when is_binary(id) do
    case actor_uri(object) do
      actor when is_binary(actor) -> same_origin(actor, id)
      _ -> {:error, :origin_containment_failed}
    end
  end

  def contain_origin(_), do: :ok

  def contain_origin_from_id(id, %{"id" => other_id})
      when is_binary(id) and is_binary(other_id) do
    same_origin(id, other_id)
  end

  def contain_origin_from_id(id, %{"object" => object})
      when is_binary(id) and is_binary(object) do
    same_origin(id, object)
  end

  def contain_origin_from_id(_id, _object), do: :ok

  def contain_fetch_origin(uri, %{"_source_url" => source_url} = object)
      when is_binary(uri) and is_binary(source_url) do
    if comparable_uri(uri) == comparable_uri(source_url) do
      contain_origin(object)
    else
      contain_origin_from_id(uri, object)
    end
  end

  def contain_fetch_origin(uri, object), do: contain_origin_from_id(uri, object)

  def contain_child(%{"object" => %{"id" => id} = object}) when is_binary(id) do
    contain_origin(object)
  end

  def contain_child(_), do: :ok

  def actor_uri(%{"actor" => actor}), do: normalize_actor(actor)
  def actor_uri(%{"attributedTo" => actor}), do: normalize_actor(actor)
  def actor_uri(%{"id" => id, "type" => type}) when type in @actor_types and is_binary(id), do: id
  def actor_uri(_), do: nil

  defp normalize_actor(actor) when is_binary(actor), do: actor
  defp normalize_actor(%{"id" => id}) when is_binary(id), do: id

  defp normalize_actor([first | _]) when is_binary(first), do: first

  defp normalize_actor(actors) when is_list(actors) do
    Enum.find_value(actors, fn
      %{"type" => type, "id" => id} when type in @actor_types and is_binary(id) -> id
      _ -> nil
    end)
  end

  defp normalize_actor(_), do: nil

  defp same_origin(left, right) when is_binary(left) and is_binary(right) do
    with %URI{host: left_host} when is_binary(left_host) <- URI.parse(left),
         %URI{host: right_host} when is_binary(right_host) <- URI.parse(right),
         true <- String.downcase(left_host) == String.downcase(right_host) do
      :ok
    else
      _ -> {:error, :origin_containment_failed}
    end
  end

  defp same_origin(_left, _right), do: {:error, :origin_containment_failed}

  defp comparable_uri(uri) when is_binary(uri) do
    uri
    |> String.trim()
    |> URI.parse()
    |> case do
      %URI{scheme: scheme, host: host} = parsed when is_binary(scheme) and is_binary(host) ->
        path = parsed.path || "/"

        parsed
        |> Map.put(:scheme, String.downcase(scheme))
        |> Map.put(:host, String.downcase(host))
        |> Map.put(:path, String.trim_trailing(path, "/"))
        |> Map.put(:fragment, nil)
        |> URI.to_string()

      _ ->
        uri
    end
  end
end
