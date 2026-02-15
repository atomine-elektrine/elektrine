defmodule Elektrine.ActivityPub.ObjectValidator do
  @moduledoc """
  Validates incoming ActivityPub objects and activities.

  Ensures objects are well-formed and compatible with our system before processing.
  This helps prevent malformed or malicious activities from causing issues.
  """

  require Logger

  @doc """
  Validates an activity before processing.
  Returns {:ok, activity} if valid, {:error, reason} if invalid.
  """
  def validate(activity) when is_map(activity) do
    with {:ok, activity} <- validate_basic_structure(activity),
         {:ok, activity} <- validate_actor(activity) do
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
        {:ok, activity}

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
    with {:ok, _} <- validate_object(object) do
      {:ok, activity}
    end
  end

  defp validate_create(%{"object" => object_uri} = activity) when is_binary(object_uri) do
    # Object is a URI reference - acceptable
    {:ok, activity}
  end

  defp validate_create(_), do: {:error, "Create activity missing object"}

  # Update validation
  defp validate_update(%{"object" => object} = activity) when is_map(object) do
    {:ok, activity}
  end

  defp validate_update(_), do: {:error, "Update activity missing object"}

  # Delete validation
  defp validate_delete(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    {:ok, activity}
  end

  defp validate_delete(_), do: {:error, "Delete activity missing object"}

  # Follow validation
  defp validate_follow(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    {:ok, activity}
  end

  defp validate_follow(_), do: {:error, "Follow activity missing object"}

  # Accept/Reject validation
  defp validate_accept_reject(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    {:ok, activity}
  end

  defp validate_accept_reject(_), do: {:error, "Accept/Reject activity missing object"}

  # Like validation
  defp validate_like(%{"object" => object} = activity) when is_binary(object) or is_map(object) do
    {:ok, activity}
  end

  defp validate_like(_), do: {:error, "Like activity missing object"}

  # Announce validation
  defp validate_announce(%{"object" => object} = activity)
       when is_binary(object) or is_map(object) do
    {:ok, activity}
  end

  defp validate_announce(_), do: {:error, "Announce activity missing object"}

  # Undo validation
  defp validate_undo(%{"object" => object} = activity) when is_binary(object) or is_map(object) do
    {:ok, activity}
  end

  defp validate_undo(_), do: {:error, "Undo activity missing object"}

  # Flag (report) validation
  defp validate_flag(%{"object" => objects} = activity)
       when is_list(objects) or is_binary(objects) do
    {:ok, activity}
  end

  defp validate_flag(_), do: {:error, "Flag activity missing object"}

  # Block validation
  defp validate_block(%{"object" => object} = activity) when is_binary(object) do
    {:ok, activity}
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

  defp validate_object(_), do: {:error, "Invalid object"}

  # Content object validation (Note, Article, etc.)
  defp validate_content_object(object) do
    # Content objects should have some content
    has_content =
      is_binary(object["content"]) or
        is_binary(object["summary"]) or
        is_binary(object["name"]) or
        is_list(object["attachment"])

    if has_content do
      {:ok, object}
    else
      {:error, "Content object has no content"}
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
    case URI.parse(actor_uri) do
      %URI{host: ^expected_domain} ->
        {:ok, actor_uri}

      %URI{host: actual_domain} ->
        {:error, "Actor domain mismatch: expected #{expected_domain}, got #{actual_domain}"}

      _ ->
        {:error, "Invalid actor URI"}
    end
  end

  def validate_actor_domain(_, _), do: {:error, "Invalid actor URI"}
end
