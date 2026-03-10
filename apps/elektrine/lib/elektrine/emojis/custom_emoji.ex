defmodule Elektrine.Emojis.CustomEmoji do
  @moduledoc """
  Schema for custom emojis, both local and from federated instances.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Elektrine.Security.URLValidator

  @unsafe_image_url_chars ~r/[\s"'<>`]/

  schema "custom_emojis" do
    field :shortcode, :string
    field :image_url, :string
    field :instance_domain, :string
    field :category, :string
    field :visible_in_picker, :boolean, default: true
    field :disabled, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(emoji, attrs) do
    emoji
    |> cast(attrs, [
      :shortcode,
      :image_url,
      :instance_domain,
      :category,
      :visible_in_picker,
      :disabled
    ])
    |> validate_required([:shortcode, :image_url])
    |> update_change(:image_url, &normalize_image_url/1)
    |> validate_format(:shortcode, ~r/^[a-zA-Z0-9_]+$/,
      message: "must contain only letters, numbers, and underscores"
    )
    |> validate_change(:image_url, fn :image_url, image_url ->
      case validate_image_url(image_url) do
        {:ok, _normalized_url} -> []
        {:error, _reason} -> [image_url: "must be a valid public http(s) URL"]
      end
    end)
    |> validate_length(:shortcode, min: 2, max: 30)
    |> unique_constraint([:shortcode, :instance_domain])
  end

  def normalize_image_url(url) when is_binary(url), do: String.trim(url)
  def normalize_image_url(url), do: url

  def validate_image_url(url) when is_binary(url) do
    normalized_url = normalize_image_url(url)
    uri = URI.parse(normalized_url)

    cond do
      normalized_url == "" ->
        {:error, :invalid_image_url}

      Regex.match?(@unsafe_image_url_chars, normalized_url) ->
        {:error, :invalid_image_url}

      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_scheme}

      !is_binary(uri.host) or uri.host == "" ->
        {:error, :missing_host}

      uri.userinfo not in [nil, ""] ->
        {:error, :userinfo_not_allowed}

      URLValidator.private_ip?(uri.host) ->
        {:error, :private_host}

      true ->
        {:ok, normalized_url}
    end
  end

  def validate_image_url(_), do: {:error, :invalid_image_url}

  @doc """
  Returns the full shortcode with colons (e.g., ":blobcat:")
  """
  def full_shortcode(%__MODULE__{shortcode: shortcode}) do
    ":#{shortcode}:"
  end

  @doc """
  Returns true if this is a local emoji (nil instance_domain)
  """
  def local?(%__MODULE__{instance_domain: nil}), do: true
  def local?(%__MODULE__{}), do: false

  @doc """
  Returns true if this emoji is from a remote instance
  """
  def remote?(%__MODULE__{} = emoji), do: !local?(emoji)
end
