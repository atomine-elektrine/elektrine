defmodule Elektrine.Messaging.MessageReaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_reactions" do
    field(:emoji, :string)
    field(:federated, :boolean, default: false)
    # Custom emoji URL for federated reactions (like Akkoma's emoji reactions)
    # Format: https://instance.com/emoji/custom/blobcat.png
    field(:emoji_url, :string)

    belongs_to(:message, Elektrine.Messaging.Message)
    belongs_to(:user, Elektrine.Accounts.User)
    belongs_to(:remote_actor, Elektrine.ActivityPub.Actor)

    timestamps()
  end

  @doc false
  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :user_id, :remote_actor_id, :emoji, :federated, :emoji_url])
    |> validate_required([:message_id, :emoji])
    # Increased for custom emoji shortcodes
    |> validate_length(:emoji, min: 1, max: 100)
    |> validate_emoji_url()
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> validate_user_or_remote_actor()
    |> unique_constraint(:remote_actor_id, name: :message_reactions_federated_unique_index)
    |> unique_constraint([:message_id, :user_id, :emoji])
  end

  # Validate emoji_url if provided
  defp validate_emoji_url(changeset) do
    case get_field(changeset, :emoji_url) do
      nil ->
        changeset

      url when is_binary(url) ->
        if valid_emoji_url?(url) do
          changeset
        else
          add_error(changeset, :emoji_url, "must be a valid HTTPS URL")
        end
    end
  end

  defp valid_emoji_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      # Allow HTTP for dev
      %URI{scheme: "http", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  # Ensure either user_id or remote_actor_id is present (but not both)
  defp validate_user_or_remote_actor(changeset) do
    user_id = get_field(changeset, :user_id)
    remote_actor_id = get_field(changeset, :remote_actor_id)

    cond do
      user_id && remote_actor_id ->
        add_error(changeset, :user_id, "cannot have both user_id and remote_actor_id")

      !user_id && !remote_actor_id ->
        add_error(changeset, :user_id, "must have either user_id or remote_actor_id")

      true ->
        changeset
    end
  end

  @doc """
  Creates a changeset for adding a reaction to a message.
  """
  def add_reaction_changeset(message_id, user_id, emoji) do
    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      user_id: user_id,
      emoji: emoji
    })
  end
end
