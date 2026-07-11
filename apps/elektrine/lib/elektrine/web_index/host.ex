defmodule Elektrine.WebIndex.Host do
  @moduledoc "Persistent robots.txt policy and request pacing for a crawled host."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:host, :string, autogenerate: false}
  schema "web_index_hosts" do
    field :robots_url, :string
    field :robots_body, :string
    field :robots_fetched_at, :utc_datetime_usec
    field :next_allowed_at, :utc_datetime_usec
    field :crawl_delay_ms, :integer, default: 1_000

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [
      :host,
      :robots_url,
      :robots_body,
      :robots_fetched_at,
      :next_allowed_at,
      :crawl_delay_ms
    ])
    |> validate_required([:host, :crawl_delay_ms])
    |> validate_number(:crawl_delay_ms,
      greater_than_or_equal_to: 250,
      less_than_or_equal_to: 30_000
    )
    |> unique_constraint(:host)
  end
end
