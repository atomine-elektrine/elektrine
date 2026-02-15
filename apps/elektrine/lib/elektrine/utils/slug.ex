defmodule Elektrine.Utils.Slug do
  @moduledoc """
  Utility functions for generating SEO-friendly slugs from titles and content.
  """

  @doc """
  Generates a SEO-friendly slug from a title.
  """
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    # Remove special chars except word chars, spaces, hyphens
    |> String.replace(~r/[^\w\s-]/, "")
    # Replace spaces with hyphens
    |> String.replace(~r/\s+/, "-")
    # Replace multiple hyphens with single
    |> String.replace(~r/-+/, "-")
    # Remove leading/trailing hyphens
    |> String.trim("-")
    # Limit length for URLs
    |> String.slice(0, 60)
  end

  def slugify(_), do: ""

  @doc """
  Generates a discussion URL slug combining post ID with title slug for SEO.
  Format: /discussions/{community_hash}/{post_id}-{title_slug}
  """
  def discussion_url_slug(post_id, title) when is_binary(title) and title != "" do
    title_slug = slugify(title)

    if title_slug != "" do
      "#{post_id}-#{title_slug}"
    else
      "#{post_id}"
    end
  end

  def discussion_url_slug(post_id, _), do: "#{post_id}"

  @doc """
  Extracts post ID from a discussion URL slug.
  Handles both formats: "123-title-slug" and "123"
  """
  def extract_post_id_from_slug(slug) when is_binary(slug) do
    case String.split(slug, "-", parts: 2) do
      [id_str | _] ->
        case Integer.parse(id_str) do
          {id, ""} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def extract_post_id_from_slug(_), do: nil
end
