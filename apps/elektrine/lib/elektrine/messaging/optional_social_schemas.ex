defmodule Elektrine.Messaging.OptionalSocialSchemas.LinkPreview do
  @moduledoc false
  use Ecto.Schema

  schema "link_previews" do
    field :url, :string
    field :title, :string
    field :description, :string
    field :image_url, :string
    field :site_name, :string
    field :favicon_url, :string
    field :status, :string
    field :error_message, :string
    field :fetched_at, :utc_datetime

    timestamps()
  end
end

defmodule Elektrine.Messaging.OptionalSocialSchemas.Poll do
  @moduledoc false
  use Ecto.Schema

  schema "polls" do
    field :question, :string
    field :closes_at, :utc_datetime
    field :allow_multiple, :boolean, default: false
    field :total_votes, :integer, default: 0
    field :voters_count, :integer, default: 0
    field :voter_uris, {:array, :string}, default: []

    belongs_to :message, Elektrine.Messaging.Message
    has_many :options, Elektrine.Messaging.OptionalSocialSchemas.PollOption, foreign_key: :poll_id

    timestamps()
  end
end

defmodule Elektrine.Messaging.OptionalSocialSchemas.PollOption do
  @moduledoc false
  use Ecto.Schema

  schema "poll_options" do
    field :option_text, :string
    field :position, :integer, default: 0
    field :vote_count, :integer, default: 0

    belongs_to :poll, Elektrine.Messaging.OptionalSocialSchemas.Poll

    timestamps()
  end
end

defmodule Elektrine.Messaging.OptionalSocialSchemas.Hashtag do
  @moduledoc false
  use Ecto.Schema

  schema "hashtags" do
    field :name, :string
    field :normalized_name, :string
    field :use_count, :integer, default: 0
    field :last_used_at, :utc_datetime

    timestamps()
  end
end
