defmodule Elektrine.Social.LinkPreview do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Elektrine.Security.SafeExternalURL

  @max_varchar_length 255
  @max_url_length 2048

  schema "link_previews" do
    field :url, :string
    field :title, :string
    field :description, :string
    field :image_url, :string
    field :site_name, :string
    field :favicon_url, :string
    field :status, :string, default: "pending"
    field :error_message, :string
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :url,
      :title,
      :description,
      :image_url,
      :site_name,
      :favicon_url,
      :status,
      :error_message,
      :fetched_at
    ])
    |> trim_field(:url)
    |> trim_field(:image_url)
    |> trim_field(:favicon_url)
    |> update_change(:fetched_at, &Elektrine.Time.truncate/1)
    |> truncate_field(:title, @max_varchar_length)
    |> truncate_field(:site_name, @max_varchar_length)
    |> nilify_overlong_field(:image_url, @max_url_length)
    |> nilify_overlong_field(:favicon_url, @max_url_length)
    |> validate_required([:url])
    |> validate_inclusion(:status, ["pending", "success", "failed"])
    |> validate_safe_href(:url)
    |> validate_optional_safe_href(:image_url)
    |> validate_optional_safe_href(:favicon_url)
    |> unique_constraint(:url)
  end

  defp trim_field(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp truncate_field(changeset, field, max_length) do
    update_change(changeset, field, fn value ->
      if is_binary(value) and String.length(value) > max_length do
        String.slice(value, 0, max_length)
      else
        value
      end
    end)
  end

  defp nilify_overlong_field(changeset, field, max_length) do
    update_change(changeset, field, fn value ->
      if is_binary(value) and String.length(value) > max_length do
        nil
      else
        value
      end
    end)
  end

  defp validate_safe_href(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      safe_href_errors(field, url)
    end)
  end

  defp validate_optional_safe_href(changeset, field) do
    validate_change(changeset, field, fn
      _, nil -> []
      _, "" -> []
      _, url -> safe_href_errors(field, url)
    end)
  end

  defp safe_href_errors(field, url) do
    case SafeExternalURL.normalize_href(url) do
      {:ok, _url} -> []
      {:error, :userinfo_not_allowed} -> [{field, "must not include username or password"}]
      {:error, _reason} -> [{field, "must be a valid HTTP or HTTPS URL"}]
    end
  end
end
