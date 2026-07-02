defmodule Elektrine.Social.Filters do
  @moduledoc """
  User-owned social filter engine shared by timelines, notifications, and feed cache.
  """

  import Ecto.Query

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias Elektrine.Social.{Filter, Message}

  def list_filters(user_id) do
    from(filter in Filter,
      where: filter.user_id == ^user_id,
      order_by: [asc: filter.kind, asc: filter.id]
    )
    |> Repo.all()
  end

  def list_active_filters(user_id, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    context = to_string(context)

    from(filter in Filter,
      where: filter.user_id == ^user_id,
      where: is_nil(filter.expires_at) or filter.expires_at > ^now,
      where: filter.contexts == [] or ^context in filter.contexts,
      order_by: [asc: filter.id]
    )
    |> Repo.all()
  end

  def create_filter(user_id, attrs) when is_map(attrs) do
    %Filter{}
    |> Filter.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  def update_filter(%Filter{} = filter, attrs) do
    filter
    |> Filter.changeset(attrs)
    |> Repo.update()
  end

  def delete_filter(filter_id, user_id) do
    case Repo.get_by(Filter, id: filter_id, user_id: user_id) do
      nil -> {:error, :not_found}
      filter -> Repo.delete(filter)
    end
  end

  def filtered?(user_id, message, context \\ :home)

  def filtered?(user_id, %Message{} = message, context) when is_integer(user_id) do
    user_id
    |> list_active_filters(context)
    |> Enum.any?(&matches?(&1, message))
  end

  def filtered?(_user_id, _message, _context), do: false

  def matches?(%Filter{kind: "keyword"} = filter, %Message{} = message) do
    haystack =
      [message.title, message.content, message.content_warning]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    text_matches?(haystack, filter.value, filter.whole_word)
  end

  def matches?(%Filter{kind: "domain", value: domain}, %Message{} = message) do
    message
    |> actor_domain()
    |> domain_matches?(domain)
  end

  def matches?(%Filter{kind: "actor", value: actor}, %Message{} = message) do
    actor = normalize_text(actor)

    actor in [
      normalize_text(message.activitypub_id),
      normalize_text(message.activitypub_url),
      normalize_text(actor_uri(message)),
      normalize_text(actor_handle(message))
    ]
  end

  def matches?(%Filter{kind: "community", value: value}, %Message{media_metadata: metadata})
      when is_map(metadata) do
    community_uri = metadata["community_actor_uri"] || metadata[:community_actor_uri]
    normalize_text(community_uri) == normalize_text(value)
  end

  def matches?(%Filter{kind: "media"}, %Message{media_urls: urls}) when is_list(urls),
    do: urls != []

  def matches?(%Filter{kind: "sensitive"}, %Message{} = message),
    do: message.sensitive == true or present?(message.content_warning)

  def matches?(%Filter{kind: "boost"}, %Message{} = message),
    do: message.post_type == "share" or is_integer(message.shared_message_id)

  def matches?(%Filter{kind: "reply"}, %Message{} = message),
    do: is_integer(message.reply_to_id) or present?(metadata_value(message, "inReplyTo"))

  def matches?(_filter, _message), do: false

  defp text_matches?(_text, nil, _whole_word), do: false

  defp text_matches?(text, value, false) do
    text
    |> normalize_text()
    |> String.contains?(normalize_text(value))
  end

  defp text_matches?(text, value, true) do
    pattern = ~r/(^|[^\p{L}\p{N}_])#{Regex.escape(normalize_text(value))}($|[^\p{L}\p{N}_])/u
    Regex.match?(pattern, normalize_text(text))
  end

  defp actor_domain(%Message{remote_actor: %Actor{domain: domain}}), do: domain

  defp actor_domain(%Message{
         remote_actor: %Ecto.Association.NotLoaded{},
         remote_actor_id: actor_id
       }),
       do: load_actor_domain(actor_id)

  defp actor_domain(%Message{remote_actor: nil, remote_actor_id: actor_id}),
    do: load_actor_domain(actor_id)

  defp actor_domain(_message), do: nil

  defp load_actor_domain(actor_id) when is_integer(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{domain: domain} -> domain
      _ -> nil
    end
  end

  defp load_actor_domain(_), do: nil

  defp domain_matches?(domain, filter_domain)
       when is_binary(domain) and is_binary(filter_domain) do
    domain = domain |> String.downcase() |> String.trim_leading(".")
    filter_domain = filter_domain |> String.downcase() |> String.trim_leading(".")

    domain == filter_domain or String.ends_with?(domain, "." <> filter_domain)
  end

  defp domain_matches?(_domain, _filter_domain), do: false

  defp actor_uri(%Message{remote_actor: %Actor{uri: uri}}), do: uri

  defp actor_uri(%Message{
         remote_actor: %Ecto.Association.NotLoaded{},
         remote_actor_id: actor_id
       }),
       do: load_actor_field(actor_id, :uri)

  defp actor_uri(%Message{remote_actor: nil, remote_actor_id: actor_id}),
    do: load_actor_field(actor_id, :uri)

  defp actor_uri(_), do: nil

  defp actor_handle(%Message{remote_actor: %Actor{username: username, domain: domain}})
       when is_binary(username) and is_binary(domain),
       do: "#{username}@#{domain}"

  defp actor_handle(%Message{
         remote_actor: %Ecto.Association.NotLoaded{},
         remote_actor_id: actor_id
       }),
       do: load_actor_handle(actor_id)

  defp actor_handle(%Message{remote_actor: nil, remote_actor_id: actor_id}),
    do: load_actor_handle(actor_id)

  defp actor_handle(_), do: nil

  defp load_actor_field(actor_id, field) when is_integer(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{} = actor -> Map.get(actor, field)
      _ -> nil
    end
  end

  defp load_actor_field(_, _), do: nil

  defp load_actor_handle(actor_id) when is_integer(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{username: username, domain: domain} when is_binary(username) and is_binary(domain) ->
        "#{username}@#{domain}"

      _ ->
        nil
    end
  end

  defp load_actor_handle(_), do: nil

  defp metadata_value(%Message{media_metadata: metadata}, key) when is_map(metadata),
    do: metadata[key] || metadata[String.to_atom(key)]

  defp metadata_value(_, _), do: nil

  defp normalize_text(value) when is_binary(value),
    do: value |> String.downcase() |> String.trim()

  defp normalize_text(_), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
