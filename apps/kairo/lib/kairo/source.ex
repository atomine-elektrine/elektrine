defmodule Kairo.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @source_types ~w(url text markdown html json file image pdf email rss_item timeline_post webhook)
  @statuses ~w(received stored processing compiled needs_review failed)

  schema "kairo_sources" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :project, Kairo.Project

    field :source_type, :string
    field :title, :string
    field :url, :string
    field :content, :string
    field :content_format, :string
    field :status, :string, default: "received"
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :raw_hash, :string
    field :error_message, :string
    field :ingested_at, :utc_datetime
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def source_types, do: @source_types
  def statuses, do: @statuses

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :user_id,
      :project_id,
      :source_type,
      :title,
      :url,
      :content,
      :content_format,
      :status,
      :tags,
      :metadata,
      :raw_hash,
      :error_message,
      :ingested_at,
      :processed_at
    ])
    |> normalize_tags()
    |> put_default_ingested_at()
    |> validate_required([:user_id, :source_type, :status, :tags, :metadata, :ingested_at])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_source_payload()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:project_id)
  end

  defp normalize_tags(changeset) do
    tags =
      changeset
      |> get_field(:tags, [])
      |> List.wrap()
      |> Enum.flat_map(&split_tag/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    put_change(changeset, :tags, tags)
  end

  defp split_tag(tag) when is_binary(tag), do: String.split(tag, ",")
  defp split_tag(tag), do: [to_string(tag)]

  defp put_default_ingested_at(changeset) do
    case get_field(changeset, :ingested_at) do
      nil -> put_change(changeset, :ingested_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _value -> changeset
    end
  end

  defp validate_source_payload(changeset) do
    if [:title, :url, :content] |> Enum.any?(&(get_field(changeset, &1) |> present?())) do
      changeset
    else
      add_error(changeset, :content, "must include title, url, or content")
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
