defmodule Elektrine.Messaging.Conversation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    field :name, :string
    field :description, :string
    field :type, :string
    field :avatar_url, :string
    field :is_public, :boolean, default: false
    field :member_count, :integer, default: 0
    field :last_message_at, :utc_datetime
    field :archived, :boolean, default: false
    field :hash, :string

    # Community features (for type = "community")
    field :community_category, :string
    field :allow_public_posts, :boolean, default: false
    field :discussion_style, :string, default: "chat"
    field :community_rules, :string

    # Moderation settings
    field :slow_mode_seconds, :integer, default: 0
    field :approval_mode_enabled, :boolean, default: false
    field :approval_threshold_posts, :integer, default: 3

    # Server-scoped channel metadata
    field :channel_topic, :string
    field :channel_position, :integer, default: 0

    # Federated community mirroring (for Lemmy, Guppe groups, etc.)
    # ActivityPub Group URI
    field :federated_source, :string
    # True if mirrors remote community
    field :is_federated_mirror, :boolean, default: false
    # Link to Group actor
    belongs_to :remote_group_actor, Elektrine.ActivityPub.Actor

    belongs_to :creator, Elektrine.Accounts.User
    belongs_to :server, Elektrine.Messaging.Server
    has_many :channels, __MODULE__, foreign_key: :server_id
    has_many :members, Elektrine.Messaging.ConversationMember, foreign_key: :conversation_id
    has_many :users, through: [:members, :user]
    has_many :messages, Elektrine.Messaging.Message, foreign_key: :conversation_id

    timestamps()
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :name,
      :description,
      :type,
      :creator_id,
      :avatar_url,
      :is_public,
      :member_count,
      :last_message_at,
      :archived,
      :community_category,
      :allow_public_posts,
      :discussion_style,
      :community_rules,
      :slow_mode_seconds,
      :approval_mode_enabled,
      :approval_threshold_posts,
      :channel_topic,
      :channel_position,
      :server_id,
      :federated_source,
      :is_federated_mirror,
      :remote_group_actor_id
    ])
    |> validate_required([:type])
    |> validate_inclusion(:type, ["dm", "group", "channel", "community", "timeline"])
    |> validate_length(:channel_topic, max: 300)
    |> validate_number(:channel_position, greater_than_or_equal_to: 0)
    |> validate_inclusion(:discussion_style, ["chat", "forum", "hybrid"])
    |> validate_inclusion(:community_category, [
      nil,
      "tech",
      "gaming",
      "art",
      "science",
      "music",
      "general",
      "sports",
      "food",
      "travel",
      "fitness",
      "movies",
      "tv",
      "books",
      "education",
      "business",
      "finance",
      "politics",
      "news",
      "fashion",
      "photography",
      "anime",
      "comics",
      "diy",
      "crafts",
      "automotive",
      "pets",
      "nature",
      "history",
      "philosophy",
      "psychology",
      "health",
      "medicine",
      "law",
      "writing",
      "programming",
      "design",
      "marketing",
      "crypto",
      "stocks",
      "realestate",
      "career",
      "relationships",
      "parenting",
      "religion",
      "spirituality",
      "comedy",
      "memes",
      "conspiracy",
      "paranormal",
      "space",
      "environment",
      "energy"
    ])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_name_security()
    |> validate_description_security()
    |> downcase_name()
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:server_id)
    |> unique_constraint(:name,
      name: :conversations_community_name_ci_unique,
      message: "A community with this name already exists"
    )
    |> unique_constraint(:federated_source,
      name: :conversations_channel_federated_source_unique,
      message: "Channel already exists from this federated source"
    )
    |> generate_hash_if_needed()
  end

  @doc """
  Creates a changeset for a direct message conversation.
  """
  def dm_changeset(conversation \\ %__MODULE__{}, attrs) do
    conversation
    |> changeset(Map.put(attrs, :type, "dm"))
  end

  @doc """
  Creates a changeset for a group conversation.
  Also used for communities - respects the type if already set to "community".
  """
  def group_changeset(conversation \\ %__MODULE__{}, attrs) do
    # Use the provided type if it's "community", otherwise default to "group"
    type = Map.get(attrs, :type, "group")

    conversation
    |> changeset(Map.put(attrs, :type, type))
    |> validate_required([:name])
    |> maybe_validate_creator_id()
  end

  @doc """
  Creates a changeset for a channel conversation.
  """
  def channel_changeset(conversation \\ %__MODULE__{}, attrs) do
    conversation
    |> changeset(Map.put(attrs, :type, "channel"))
    |> validate_required([:name])
    |> maybe_validate_creator_id()
  end

  @doc """
  Returns display name for the conversation from a user's perspective.
  """
  def display_name(%__MODULE__{type: "dm", members: members}, current_user_id) do
    case Enum.find(members, fn member ->
           member.user_id != current_user_id and is_nil(member.left_at)
         end) do
      %{user: user} -> user.display_name || user.username
      nil -> "Unknown User"
    end
  end

  def display_name(%__MODULE__{name: name}, _current_user_id) do
    name || "Unnamed Conversation"
  end

  @doc """
  Returns the avatar URL for the conversation from a user's perspective.
  """
  def avatar_url(%__MODULE__{type: "dm", members: members}, current_user_id) do
    case Enum.find(members, fn member ->
           member.user_id != current_user_id and is_nil(member.left_at)
         end) do
      %{user: user} -> user.avatar
      nil -> nil
    end
  end

  def avatar_url(%__MODULE__{avatar_url: avatar_url}, _current_user_id) do
    avatar_url
  end

  # Security validation functions

  defp validate_name_security(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name when is_binary(name) ->
        # Remove potentially dangerous content from names
        cleaned_name =
          name
          # Remove HTML tags
          |> String.replace(~r/<[^>]+>/, "")
          |> String.replace(~r/javascript:/i, "")
          |> String.trim()

        if String.length(cleaned_name) != String.length(name) do
          add_error(changeset, :name, "contains invalid characters")
        else
          put_change(changeset, :name, cleaned_name)
        end

      _ ->
        changeset
    end
  end

  defp validate_description_security(changeset) do
    case get_change(changeset, :description) do
      nil ->
        changeset

      description when is_binary(description) ->
        # Remove potentially dangerous content from descriptions
        cleaned_description =
          description
          |> String.replace(~r/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/mi, "")
          |> String.replace(~r/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/mi, "")
          |> String.replace(~r/javascript:/i, "")
          |> String.trim()

        if String.length(cleaned_description) != String.length(description) do
          add_error(changeset, :description, "contains potentially unsafe content")
        else
          put_change(changeset, :description, cleaned_description)
        end

      _ ->
        changeset
    end
  end

  # Convert community name to lowercase for case-insensitive uniqueness
  defp downcase_name(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name when is_binary(name) ->
        put_change(changeset, :name, String.downcase(name))

      _ ->
        changeset
    end
  end

  # Generate a unique hash for the conversation if it doesn't have one
  defp generate_hash_if_needed(changeset) do
    case get_field(changeset, :hash) do
      nil ->
        hash = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
        put_change(changeset, :hash, hash)

      _ ->
        changeset
    end
  end

  defp maybe_validate_creator_id(changeset) do
    if get_field(changeset, :is_federated_mirror) do
      changeset
    else
      validate_required(changeset, [:creator_id])
    end
  end
end
