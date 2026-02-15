defmodule Elektrine.Emojis.CustomEmoji do
  @moduledoc """
  Schema for custom emojis, both local and from federated instances.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
    |> validate_format(:shortcode, ~r/^[a-zA-Z0-9_]+$/,
      message: "must contain only letters, numbers, and underscores"
    )
    |> validate_length(:shortcode, min: 2, max: 30)
    |> unique_constraint([:shortcode, :instance_domain])
  end

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
