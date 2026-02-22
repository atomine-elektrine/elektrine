defmodule Elektrine.ActivityPub.Actor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_actors" do
    field :uri, :string
    field :username, :string
    field :domain, :string
    field :display_name, :string
    field :summary, :string
    field :avatar_url, :string
    field :header_url, :string
    field :inbox_url, :string
    field :outbox_url, :string
    field :followers_url, :string
    field :following_url, :string
    field :public_key, :string
    field :manually_approves_followers, :boolean, default: false
    field :actor_type, :string, default: "Person"
    field :last_fetched_at, :utc_datetime
    field :published_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :moderators_url, :string

    # Relationship to local community (if this actor represents a local community)
    belongs_to :community, Elektrine.Messaging.Conversation, foreign_key: :community_id

    timestamps()
  end

  @doc false
  def changeset(actor, attrs) do
    actor
    |> cast(attrs, [
      :uri,
      :username,
      :domain,
      :display_name,
      :summary,
      :avatar_url,
      :header_url,
      :inbox_url,
      :outbox_url,
      :followers_url,
      :following_url,
      :public_key,
      :manually_approves_followers,
      :actor_type,
      :last_fetched_at,
      :published_at,
      :metadata,
      :moderators_url,
      :community_id
    ])
    |> validate_required([:uri, :username, :domain, :inbox_url])
    |> validate_inclusion(:actor_type, [
      "Person",
      "Group",
      "Organization",
      "Service",
      "Application"
    ])
    |> unique_constraint(:uri)
    |> unique_constraint([:username, :domain],
      name: :activitypub_actors_username_domain_unique_index
    )
    |> unique_constraint(:community_id)
  end
end
