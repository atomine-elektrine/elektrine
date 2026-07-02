defmodule Elektrine.ActivityPub.ObjectValidator do
  @moduledoc """
  Validates incoming ActivityPub objects and activities.

  Ensures objects are well-formed and compatible with our system before processing.
  This helps prevent malformed or malicious activities from causing issues.
  """

  alias Elektrine.ActivityPub.Containment
  alias Elektrine.Security.URLValidator

  @doc """
  Validates an activity before processing.
  Returns {:ok, activity} if valid, {:error, reason} if invalid.
  """
  def validate(activity) when is_map(activity) do
    with {:ok, activity} <- validate_basic_structure(activity),
         {:ok, activity} <- validate_actor(activity),
         :ok <- Containment.validate_activity(activity) do
      validate_type_specific(activity)
    end
  end

  def validate(_), do: {:error, "Activity must be a map"}

  # Basic structure validation - all activities need these
  defp validate_basic_structure(activity) do
    cond do
      !is_binary(activity["type"]) ->
        {:error, "Missing or invalid type"}

      !has_valid_id?(activity) ->
        {:error, "Missing or invalid id"}

      is_binary(activity["id"]) and not valid_uri?(activity["id"]) ->
        {:error, "Invalid activity id"}

      true ->
        {:ok, activity}
    end
  end

  defp has_valid_id?(%{"id" => id}) when is_binary(id) and byte_size(id) > 0, do: true
  # Delete activities may not have id
  defp has_valid_id?(%{"type" => "Delete"}), do: true
  defp has_valid_id?(_), do: false

  # Actor validation
  defp validate_actor(%{"actor" => actor} = activity) when is_binary(actor) do
    case URI.parse(actor) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if URLValidator.private_ip?(host) or URLValidator.is_private_domain?(host) do
          {:error, "Invalid actor URI"}
        else
          {:ok, activity}
        end

      _ ->
        {:error, "Invalid actor URI"}
    end
  end

  defp validate_actor(%{"type" => type} = activity)
       when type in ["Person", "Group", "Application", "Service", "Organization"] do
    # Actor objects don't have an "actor" field, they ARE the actor
    {:ok, activity}
  end

  defp validate_actor(_), do: {:error, "Missing or invalid actor"}

  # Type-specific validation
  defp validate_type_specific(%{"type" => "Create"} = activity), do: validate_create(activity)
  defp validate_type_specific(%{"type" => "Update"} = activity), do: validate_update(activity)
  defp validate_type_specific(%{"type" => "Delete"} = activity), do: validate_delete(activity)
  defp validate_type_specific(%{"type" => "Follow"} = activity), do: validate_follow(activity)

  defp validate_type_specific(%{"type" => "Accept"} = activity),
    do: validate_accept_reject(activity)

  defp validate_type_specific(%{"type" => "Reject"} = activity),
    do: validate_accept_reject(activity)

  defp validate_type_specific(%{"type" => "Like"} = activity), do: validate_like(activity)
  defp validate_type_specific(%{"type" => "Announce"} = activity), do: validate_announce(activity)
  defp validate_type_specific(%{"type" => "Move"} = activity), do: validate_move(activity)
  defp validate_type_specific(%{"type" => "Undo"} = activity), do: validate_undo(activity)
  defp validate_type_specific(%{"type" => "Flag"} = activity), do: validate_flag(activity)
  defp validate_type_specific(%{"type" => "Block"} = activity), do: validate_block(activity)

  defp validate_type_specific(%{"type" => type} = activity)
       when type in ["Person", "Group", "Application", "Service", "Organization"] do
    validate_actor_object(activity)
  end

  # Unknown types pass through
  defp validate_type_specific(activity), do: {:ok, activity}

  # Create validation
  defp validate_create(%{"object" => object} = activity) when is_map(object) do
    object = normalize_embedded_object(object)

    with {:ok, object} <- validate_object(object),
         :ok <- validate_object_author_matches_activity(activity, object),
         :ok <- validate_object_addressing_matches_activity(activity, object) do
      {:ok, Map.put(activity, "object", object)}
    end
  end

  defp validate_create(%{"object" => object_uri} = activity) when is_binary(object_uri) do
    if valid_uri?(object_uri), do: {:ok, activity}, else: {:error, "Create object URI invalid"}
  end

  defp validate_create(_), do: {:error, "Create activity missing object"}

  # Update validation
  defp validate_update(%{"object" => object} = activity) when is_map(object) do
    object = normalize_embedded_object(object)

    with {:ok, object} <- validate_object(object),
         :ok <- validate_object_author_matches_activity(activity, object),
         :ok <- validate_object_addressing_matches_activity(activity, object) do
      {:ok, Map.put(activity, "object", object)}
    end
  end

  defp validate_update(%{"object" => object_uri} = activity) when is_binary(object_uri) do
    if valid_uri?(object_uri), do: {:ok, activity}, else: {:error, "Update object URI invalid"}
  end

  defp validate_update(_), do: {:error, "Update activity missing object"}

  # Delete validation
  defp validate_delete(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    validate_object_ref_or_map(activity, object, "Delete object URI invalid")
  end

  defp validate_delete(_), do: {:error, "Delete activity missing object"}

  # Follow validation
  defp validate_follow(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    validate_object_ref_or_map(activity, object, "Follow object URI invalid")
  end

  defp validate_follow(_), do: {:error, "Follow activity missing object"}

  # Accept/Reject validation
  defp validate_accept_reject(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    validate_object_ref_or_map(activity, object, "Accept/Reject object URI invalid")
  end

  defp validate_accept_reject(_), do: {:error, "Accept/Reject activity missing object"}

  # Like validation
  defp validate_like(%{"object" => object} = activity) when is_binary(object) or is_map(object) do
    validate_object_ref_or_map(activity, object, "Like object URI invalid")
  end

  defp validate_like(_), do: {:error, "Like activity missing object"}

  # Announce validation
  defp validate_announce(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    validate_object_ref_or_map(activity, object, "Announce object URI invalid")
  end

  defp validate_announce(%{"object" => objects} = activity) when is_list(objects) do
    if Enum.all?(objects, &announce_object_ref?/1) do
      {:ok, activity}
    else
      {:error, "Announce activity has invalid object list"}
    end
  end

  defp validate_announce(_), do: {:error, "Announce activity missing object"}

  # Move validation
  defp validate_move(%{"object" => object, "target" => target} = activity)
       when (is_binary(object) or is_map(object)) and (is_binary(target) or is_map(target)) do
    with {:ok, activity} <-
           validate_object_ref_or_map(activity, object, "Move object URI invalid"),
         :ok <- validate_ref_or_map(target, "Move target URI invalid") do
      {:ok, activity}
    end
  end

  defp validate_move(%{"object" => _}), do: {:error, "Move activity missing target"}
  defp validate_move(_), do: {:error, "Move activity missing object"}

  defp announce_object_ref?(object) when is_binary(object) or is_map(object), do: true
  defp announce_object_ref?(_), do: false

  # Undo validation
  defp validate_undo(%{"object" => object} = activity) when is_binary(object) or is_map(object) do
    validate_object_ref_or_map(activity, object, "Undo object URI invalid")
  end

  defp validate_undo(_), do: {:error, "Undo activity missing object"}

  # Flag (report) validation
  defp validate_flag(%{"object" => objects} = activity)
       when is_list(objects) or is_binary(objects) do
    objects
    |> List.wrap()
    |> Enum.all?(fn
      object when is_binary(object) -> valid_uri?(object)
      _ -> true
    end)
    |> if(do: {:ok, activity}, else: {:error, "Flag object URI invalid"})
  end

  defp validate_flag(_), do: {:error, "Flag activity missing object"}

  # Block validation
  defp validate_block(%{"object" => object} = activity) when is_binary(object) do
    if valid_uri?(object), do: {:ok, activity}, else: {:error, "Block object URI invalid"}
  end

  defp validate_block(_), do: {:error, "Block activity missing object"}

  # Object validation (for embedded objects in Create/Update)
  defp validate_object(object) when is_map(object) do
    cond do
      !is_binary(object["type"]) ->
        {:error, "Object missing type"}

      object["type"] in [
        "Note",
        "Article",
        "Page",
        "Question",
        "Event",
        "Audio",
        "Video",
        "Image"
      ] ->
        validate_content_object(object)

      true ->
        {:ok, object}
    end
  end

  # Content object validation (Note, Article, etc.)
  defp validate_content_object(object) do
    # Content objects should have some content
    has_content =
      is_binary(object["content"]) or
        is_binary(object["summary"]) or
        is_binary(object["name"]) or
        is_list(object["attachment"])

    cond do
      not has_content ->
        {:error, "Content object has no content"}

      not object_identity_valid?(object) ->
        {:error, "Content object has invalid id or url"}

      not attachments_valid?(object["attachment"]) ->
        {:error, "Content object has invalid attachment"}

      not tags_valid?(object["tag"]) ->
        {:error, "Content object has invalid tag"}

      object["type"] == "Question" and not question_options_valid?(object) ->
        {:error, "Question object has invalid options"}

      true ->
        {:ok, object}
    end
  end

  # Actor object validation
  defp validate_actor_object(actor) do
    cond do
      !is_binary(actor["id"]) ->
        {:error, "Actor missing id"}

      !is_binary(actor["inbox"]) ->
        {:error, "Actor missing inbox"}

      !valid_uri?(actor["id"]) ->
        {:error, "Actor id is not a valid URI"}

      !valid_uri?(actor["inbox"]) ->
        {:error, "Actor inbox is not a valid URI"}

      true ->
        {:ok, actor}
    end
  end

  # URI validation helper
  defp valid_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        true

      _ ->
        false
    end
  end

  defp valid_uri?(_), do: false

  defp safe_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        not URLValidator.private_ip?(host) and not URLValidator.is_private_domain?(host)

      _ ->
        false
    end
  end

  defp safe_uri?(_), do: false

  defp validate_object_ref_or_map(activity, object, error_message) when is_binary(object) do
    if valid_uri?(object), do: {:ok, activity}, else: {:error, error_message}
  end

  defp validate_object_ref_or_map(activity, object, _error_message) when is_map(object) do
    object = normalize_embedded_object(object)

    with {:ok, object} <- validate_object(object) do
      {:ok, Map.put(activity, "object", object)}
    end
  end

  defp validate_ref_or_map(object, error_message) when is_binary(object) do
    if valid_uri?(object), do: :ok, else: {:error, error_message}
  end

  defp validate_ref_or_map(object, _error_message) when is_map(object) do
    object
    |> normalize_embedded_object()
    |> validate_object()
    |> case do
      {:ok, _object} -> :ok
      error -> error
    end
  end

  defp normalize_embedded_object(object) when is_map(object) do
    object
    |> normalize_quote_url()
    |> normalize_map_list_field("attachment")
    |> normalize_map_list_field("tag")
  end

  defp normalize_quote_url(%{"quoteUrl" => _} = object), do: object

  defp normalize_quote_url(%{"quoteUri" => quote_url} = object),
    do: Map.put(object, "quoteUrl", quote_url)

  defp normalize_quote_url(%{"quoteURL" => quote_url} = object),
    do: Map.put(object, "quoteUrl", quote_url)

  defp normalize_quote_url(%{"_misskey_quote" => quote_url} = object),
    do: Map.put(object, "quoteUrl", quote_url)

  defp normalize_quote_url(object), do: object

  defp normalize_map_list_field(object, field) do
    case Map.get(object, field) do
      value when is_map(value) -> Map.put(object, field, [value])
      values when is_list(values) -> Map.put(object, field, Enum.filter(values, &is_map/1))
      nil -> object
      _ -> Map.delete(object, field)
    end
  end

  defp validate_object_author_matches_activity(%{"actor" => actor}, object)
       when is_binary(actor) do
    object_actors =
      object
      |> Map.take(["actor", "attributedTo"])
      |> Map.values()
      |> Enum.flat_map(&actor_refs/1)
      |> Enum.uniq()

    if object_actors == [] or actor in object_actors do
      :ok
    else
      {:error, "Object actor does not match activity actor"}
    end
  end

  defp validate_object_author_matches_activity(_activity, _object), do: :ok

  defp actor_refs(value) when is_binary(value), do: [value]
  defp actor_refs(values) when is_list(values), do: Enum.flat_map(values, &actor_refs/1)
  defp actor_refs(%{"id" => id}) when is_binary(id), do: [id]
  defp actor_refs(%{"href" => href}) when is_binary(href), do: [href]
  defp actor_refs(_), do: []

  defp validate_object_addressing_matches_activity(activity, object) do
    ["to", "cc", "bto", "bcc"]
    |> Enum.find_value(:ok, fn field ->
      activity_recipients = Map.get(activity, field)
      object_recipients = Map.get(object, field)

      cond do
        is_nil(activity_recipients) or is_nil(object_recipients) ->
          false

        recipient_set(activity_recipients) == recipient_set(object_recipients) ->
          false

        true ->
          {:error, "Object #{field} does not match activity #{field}"}
      end
    end)
  end

  defp recipient_set(values) when is_list(values),
    do: values |> Enum.filter(&is_binary/1) |> MapSet.new()

  defp recipient_set(value) when is_binary(value), do: MapSet.new([value])
  defp recipient_set(_), do: MapSet.new()

  defp object_identity_valid?(object) do
    ["id", "url"]
    |> Enum.all?(fn field ->
      case Map.get(object, field) do
        nil -> true
        uri when is_binary(uri) -> safe_uri?(uri)
        %{"href" => href} when is_binary(href) -> safe_uri?(href)
        values when is_list(values) -> Enum.all?(values, &url_value_valid?/1)
        _ -> false
      end
    end)
  end

  defp url_value_valid?(uri) when is_binary(uri), do: safe_uri?(uri)
  defp url_value_valid?(%{"href" => href}) when is_binary(href), do: safe_uri?(href)
  defp url_value_valid?(_), do: false

  defp attachments_valid?(nil), do: true

  defp attachments_valid?(attachments) when is_list(attachments),
    do: Enum.all?(attachments, &attachment_valid?/1)

  defp attachments_valid?(_), do: false

  defp attachment_valid?(attachment) when is_map(attachment) do
    type = attachment["type"] || "Document"
    media_type = attachment["mediaType"] || attachment["mimeType"] || "application/octet-stream"
    url = attachment["url"] || attachment["href"]

    type in ["Document", "Audio", "Image", "Video", "Link"] and mime_type_valid?(media_type) and
      attachment_url_valid?(url)
  end

  defp attachment_valid?(_), do: false

  defp attachment_url_valid?(nil), do: true
  defp attachment_url_valid?(url) when is_binary(url), do: safe_uri?(url)
  defp attachment_url_valid?(%{"href" => href}) when is_binary(href), do: safe_uri?(href)

  defp attachment_url_valid?(urls) when is_list(urls),
    do: Enum.all?(urls, &attachment_url_valid?/1)

  defp attachment_url_valid?(_), do: false

  defp tags_valid?(nil), do: true
  defp tags_valid?(tags) when is_list(tags), do: Enum.all?(tags, &tag_valid?/1)
  defp tags_valid?(_), do: false

  defp tag_valid?(%{"type" => "Mention", "href" => href}), do: safe_uri?(href)

  defp tag_valid?(%{"type" => "Hashtag", "name" => name}),
    do: is_binary(name) and String.trim(name) != ""

  defp tag_valid?(%{"type" => "Emoji", "name" => name, "icon" => %{"url" => url}}),
    do: is_binary(name) and safe_uri?(url)

  defp tag_valid?(%{"type" => "Link", "href" => href} = tag),
    do: safe_uri?(href) and mime_type_valid?(tag["mediaType"] || "application/activity+json")

  defp tag_valid?(%{"type" => type}) when is_binary(type), do: true
  defp tag_valid?(_), do: false

  defp question_options_valid?(%{"oneOf" => options}) when is_list(options),
    do: poll_options_valid?(options)

  defp question_options_valid?(%{"anyOf" => options}) when is_list(options),
    do: poll_options_valid?(options)

  defp question_options_valid?(_), do: false

  defp poll_options_valid?(options) do
    options != [] and
      Enum.all?(options, fn
        %{"type" => "Note", "name" => name} -> is_binary(name) and String.trim(name) != ""
        %{"name" => name} -> is_binary(name) and String.trim(name) != ""
        _ -> false
      end)
  end

  defp mime_type_valid?(value) when is_binary(value) do
    Regex.match?(~r/^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*(?:\s*;.*)?$/i, value)
  end

  defp mime_type_valid?(_), do: false

  @doc """
  Quick validation check - returns true if object looks valid, false otherwise.
  Useful for filtering before full processing.
  """
  def valid?(object) when is_map(object) do
    case validate(object) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc """
  Returns the validation error message, or nil if valid.
  """
  def error_message(object) when is_map(object) do
    case validate(object) do
      {:ok, _} -> nil
      {:error, message} -> message
    end
  end

  def error_message(_), do: "Activity must be a map"

  @doc """
  Validates that a URI is well-formed and uses http(s).
  """
  def validate_uri(uri) when is_binary(uri) do
    if valid_uri?(uri) do
      {:ok, uri}
    else
      {:error, "Invalid URI: #{uri}"}
    end
  end

  def validate_uri(_), do: {:error, "URI must be a string"}

  @doc """
  Validates that an actor URI matches the expected domain.
  Used to prevent actor spoofing.
  """
  def validate_actor_domain(actor_uri, expected_domain) when is_binary(actor_uri) do
    case URI.parse(actor_uri).host do
      ^expected_domain ->
        {:ok, actor_uri}

      actual_domain when is_binary(actual_domain) ->
        {:error, "Actor domain mismatch: expected #{expected_domain}, got #{actual_domain}"}

      nil ->
        {:error, "Invalid actor URI"}
    end
  end

  def validate_actor_domain(_, _), do: {:error, "Invalid actor URI"}
end
