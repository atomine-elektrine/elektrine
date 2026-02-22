defmodule Elektrine.Emojis do
  @moduledoc """
  Context for managing custom emojis from local and federated instances.
  """
  import Ecto.Query
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo

  @doc """
  Gets a custom emoji by shortcode and instance domain.
  Returns nil if not found.
  """
  def get_custom_emoji(shortcode, instance_domain \\ nil) do
    Repo.one(
      from e in CustomEmoji,
        where: e.shortcode == ^shortcode and e.instance_domain == ^instance_domain
    )
  end

  @doc """
  Gets or creates a custom emoji from ActivityPub emoji data.

  Expected format from ActivityPub:
  %{
    "type" => "Emoji",
    "name" => ":blobcat:",
    "icon" => %{
      "url" => "https://mastodon.social/emoji/blobcat.png"
    }
  }
  """
  def get_or_create_from_activitypub(emoji_data, instance_domain) do
    with {:ok, shortcode} <- extract_shortcode(emoji_data["name"]),
         {:ok, image_url} <- extract_image_url(emoji_data) do
      case get_custom_emoji(shortcode, instance_domain) do
        nil ->
          %CustomEmoji{}
          |> CustomEmoji.changeset(%{
            shortcode: shortcode,
            image_url: image_url,
            instance_domain: instance_domain,
            visible_in_picker: false
          })
          |> Repo.insert()

        emoji ->
          # Update image URL if changed
          if emoji.image_url != image_url do
            emoji
            |> CustomEmoji.changeset(%{image_url: image_url})
            |> Repo.update()
          else
            {:ok, emoji}
          end
      end
    end
  end

  @doc """
  Processes ActivityPub tags array and caches any custom emojis.
  Returns a list of cached emojis.
  """
  def process_activitypub_tags(tags, instance_domain) when is_list(tags) do
    tags
    |> Enum.filter(&(&1["type"] == "Emoji"))
    |> Enum.map(fn emoji_data ->
      case get_or_create_from_activitypub(emoji_data, instance_domain) do
        {:ok, emoji} -> emoji
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def process_activitypub_tags(_, _), do: []

  @doc """
  Lists all custom emojis visible in the picker.
  """
  def list_picker_emojis do
    Repo.all(
      from e in CustomEmoji,
        where: e.visible_in_picker == true and e.disabled == false,
        order_by: [asc: e.category, asc: e.shortcode]
    )
  end

  @doc """
  Lists all custom emojis from a specific instance.
  """
  def list_instance_emojis(instance_domain) do
    Repo.all(
      from e in CustomEmoji,
        where: e.instance_domain == ^instance_domain and e.disabled == false,
        order_by: [asc: e.shortcode]
    )
  end

  @doc """
  Searches for custom emojis by shortcode.
  """
  def search_emojis(query, limit \\ 20) do
    pattern = "%#{query}%"

    Repo.all(
      from e in CustomEmoji,
        where: ilike(e.shortcode, ^pattern) and e.disabled == false,
        order_by: [asc: fragment("length(?)", e.shortcode), asc: e.shortcode],
        limit: ^limit
    )
  end

  @doc """
  Parses text and replaces custom emoji shortcodes with HTML img tags.
  Returns {processed_text, list_of_used_emojis}

  Optional instance_domain parameter to filter emojis by instance.
  """
  def render_custom_emojis(text, instance_domain \\ nil)

  def render_custom_emojis(text, instance_domain) when is_binary(text) do
    # Find all :shortcode: patterns
    shortcode_pattern = ~r/:([a-zA-Z0-9_]+):/

    matches =
      shortcode_pattern
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    if matches == [] do
      {text, []}
    else
      # Fetch all matching emojis from database
      emojis = fetch_emojis_by_shortcodes(matches, instance_domain)
      emoji_map = Map.new(emojis, fn emoji -> {emoji.shortcode, emoji} end)

      # Replace shortcodes with img tags
      processed_text =
        Regex.replace(shortcode_pattern, text, fn full_match, shortcode ->
          case Map.get(emoji_map, shortcode) do
            nil ->
              full_match

            emoji ->
              ~s(<img src="#{emoji.image_url}" alt=":#{shortcode}:" title=":#{shortcode}:" class="custom-emoji" />)
          end
        end)

      {processed_text, Map.values(emoji_map)}
    end
  end

  def render_custom_emojis(nil, _instance_domain), do: {nil, []}
  def render_custom_emojis(text, _instance_domain), do: {text, []}

  @doc """
  Returns HTML for a custom emoji shortcode (for use in reactions).
  Returns the shortcode itself if emoji not found.
  """
  def render_emoji_html(shortcode) when is_binary(shortcode) do
    if String.starts_with?(shortcode, ":") and String.ends_with?(shortcode, ":") do
      # Custom emoji shortcode format
      clean_shortcode = shortcode |> String.trim_leading(":") |> String.trim_trailing(":")

      case fetch_emoji_by_shortcode(clean_shortcode) do
        nil ->
          shortcode

        emoji ->
          ~s(<img src="#{emoji.image_url}" alt="#{shortcode}" title="#{shortcode}" class="custom-emoji inline-emoji" />)
      end
    else
      # Regular Unicode emoji
      shortcode
    end
  end

  # Private functions

  defp extract_shortcode(name) when is_binary(name) do
    # Remove colons from :shortcode:
    shortcode =
      name
      |> String.trim_leading(":")
      |> String.trim_trailing(":")

    if String.match?(shortcode, ~r/^[a-zA-Z0-9_]+$/) do
      {:ok, shortcode}
    else
      {:error, :invalid_shortcode}
    end
  end

  defp extract_shortcode(_), do: {:error, :invalid_shortcode}

  defp extract_image_url(%{"icon" => %{"url" => url}}) when is_binary(url) do
    {:ok, url}
  end

  defp extract_image_url(_), do: {:error, :missing_image_url}

  defp fetch_emojis_by_shortcodes(shortcodes, instance_domain) do
    query =
      from e in CustomEmoji,
        where: e.shortcode in ^shortcodes and e.disabled == false

    # If instance_domain is provided, filter by it; otherwise get from any instance
    query =
      if instance_domain do
        from e in query, where: e.instance_domain == ^instance_domain
      else
        query
      end

    Repo.all(query)
  end

  defp fetch_emoji_by_shortcode(shortcode) do
    Repo.one(
      from e in CustomEmoji,
        where: e.shortcode == ^shortcode and e.disabled == false,
        limit: 1
    )
  end

  # ==================== Admin Functions ====================

  @doc """
  Lists all custom emojis for admin management.
  Includes both local and federated emojis.
  """
  def list_all_emojis(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    filter = Keyword.get(opts, :filter, "all")

    query =
      from e in CustomEmoji,
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        offset: ^offset

    # Apply search filter
    query =
      if search && search != "" do
        pattern = "%#{search}%"
        from e in query, where: ilike(e.shortcode, ^pattern) or ilike(e.category, ^pattern)
      else
        query
      end

    # Apply type filter
    query =
      case filter do
        "local" -> from(e in query, where: is_nil(e.instance_domain))
        "remote" -> from(e in query, where: not is_nil(e.instance_domain))
        "enabled" -> from(e in query, where: e.disabled == false)
        "disabled" -> from(e in query, where: e.disabled == true)
        _ -> query
      end

    Repo.all(query)
  end

  @doc """
  Counts all custom emojis.
  """
  def count_emojis(opts \\ []) do
    filter = Keyword.get(opts, :filter, "all")
    search = Keyword.get(opts, :search)

    query = from(e in CustomEmoji)

    query =
      if search && search != "" do
        pattern = "%#{search}%"
        from e in query, where: ilike(e.shortcode, ^pattern) or ilike(e.category, ^pattern)
      else
        query
      end

    query =
      case filter do
        "local" -> from(e in query, where: is_nil(e.instance_domain))
        "remote" -> from(e in query, where: not is_nil(e.instance_domain))
        "enabled" -> from(e in query, where: e.disabled == false)
        "disabled" -> from(e in query, where: e.disabled == true)
        _ -> query
      end

    Repo.aggregate(query, :count, :id)
  end

  @doc """
  Gets a single emoji by ID.
  """
  def get_emoji(id) do
    Repo.get(CustomEmoji, id)
  end

  @doc """
  Creates a new local custom emoji.
  """
  def create_emoji(attrs) do
    %CustomEmoji{}
    |> CustomEmoji.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing emoji.
  """
  def update_emoji(%CustomEmoji{} = emoji, attrs) do
    emoji
    |> CustomEmoji.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an emoji.
  """
  def delete_emoji(%CustomEmoji{} = emoji) do
    Repo.delete(emoji)
  end

  @doc """
  Toggles the disabled status of an emoji.
  """
  def toggle_emoji_disabled(%CustomEmoji{} = emoji) do
    update_emoji(emoji, %{disabled: !emoji.disabled})
  end

  @doc """
  Toggles visibility in the picker.
  """
  def toggle_emoji_visibility(%CustomEmoji{} = emoji) do
    update_emoji(emoji, %{visible_in_picker: !emoji.visible_in_picker})
  end

  @doc """
  Lists all unique categories.
  """
  def list_categories do
    from(e in CustomEmoji,
      where: not is_nil(e.category) and e.category != "",
      distinct: true,
      select: e.category,
      order_by: e.category
    )
    |> Repo.all()
  end

  @doc """
  Imports emojis from a pack (list of shortcode/URL pairs).
  """
  def import_emoji_pack(emojis, category \\ nil) when is_list(emojis) do
    results =
      Enum.map(emojis, fn
        %{shortcode: shortcode, url: url} ->
          attrs = %{
            shortcode: shortcode,
            image_url: url,
            category: category,
            visible_in_picker: true,
            disabled: false
          }

          case create_emoji(attrs) do
            {:ok, emoji} -> {:ok, emoji}
            {:error, changeset} -> {:error, shortcode, changeset}
          end

        _ ->
          {:error, :invalid_format}
      end)

    successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    failures = Enum.count(results, fn r -> !match?({:ok, _}, r) end)

    {:ok, %{imported: successes, failed: failures}}
  end
end
