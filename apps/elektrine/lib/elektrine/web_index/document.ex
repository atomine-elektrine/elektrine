defmodule Elektrine.WebIndex.Document do
  @moduledoc "A URL in Paige's crawl frontier and independent search index."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending fetching indexed duplicate blocked failed gone noindex)

  schema "web_index_documents" do
    field :url, :string
    field :canonical_url, :string
    field :host, :string
    field :discovered_from, :string
    field :depth, :integer, default: 0
    field :status, :string, default: "pending"
    field :title, :string
    field :description, :string
    field :content, :string
    field :content_hash, :binary
    field :language, :string
    field :http_status, :integer
    field :attempts, :integer, default: 0
    field :fetched_at, :utc_datetime_usec
    field :next_fetch_at, :utc_datetime_usec
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :url,
      :canonical_url,
      :host,
      :discovered_from,
      :depth,
      :status,
      :title,
      :description,
      :content,
      :content_hash,
      :language,
      :http_status,
      :attempts,
      :fetched_at,
      :next_fetch_at,
      :last_error
    ])
    |> validate_required([:url, :canonical_url, :host, :depth, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:depth, greater_than_or_equal_to: 0)
    |> unique_constraint(:canonical_url)
    |> foreign_key_constraint(:host)
  end
end
