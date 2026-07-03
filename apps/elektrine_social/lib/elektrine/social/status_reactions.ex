defmodule Elektrine.Social.StatusReactions do
  @moduledoc """
  Status engagement queries (liked/boosted-by accounts, quotes) and emoji reactions.
  """

  import Ecto.Query, warn: false
  import Elektrine.Social.FeedQuery

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.MessagePolicy
  alias Elektrine.Social.MessageReaction
  alias Elektrine.Social.Messages, as: MessagingMessages
  alias Elektrine.Social.PostBoost
  alias Elektrine.Social.PostLike

  def status_liked_by_accounts(message_id, limit \\ 80) do
    from(like in PostLike,
      join: account in assoc(like, :user),
      where: like.message_id == ^message_id,
      order_by: [desc: like.id],
      limit: ^limit,
      select: account
    )
    |> Repo.all()
  end

  def status_boosted_by_accounts(message_id, limit \\ 80) do
    from(boost in PostBoost,
      join: account in assoc(boost, :user),
      where: boost.message_id == ^message_id,
      order_by: [desc: boost.id],
      limit: ^limit,
      select: account
    )
    |> Repo.all()
  end

  def list_status_quotes(message_id, viewer_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = pagination_opts(opts)
    preloads = MessagingMessages.timeline_feed_preloads()

    from(message in Message,
      where:
        message.quoted_message_id == ^message_id and
          message.is_draft != true and
          is_nil(message.deleted_at) and
          (message.approval_status == "approved" or is_nil(message.approval_status)),
      order_by: [desc: message.id],
      limit: ^(limit * 3),
      preload: ^preloads
    )
    |> apply_id_pagination(pagination)
    |> apply_id_order(pagination.order)
    |> Repo.all()
    |> Enum.filter(&MessagePolicy.visible?(viewer_id, &1))
    |> Enum.take(limit)
  end

  def list_status_reactions(message_id, opts \\ []) do
    emoji = Keyword.get(opts, :emoji)

    query =
      from(reaction in MessageReaction,
        where: reaction.message_id == ^message_id,
        order_by: [asc: reaction.inserted_at, asc: reaction.id],
        preload: [:user, :remote_actor]
      )

    query =
      if is_binary(emoji) and emoji != "" do
        from(reaction in query, where: reaction.emoji == ^emoji)
      else
        query
      end

    Repo.all(query)
  end

  def add_status_reaction(user_id, message_id, emoji)
      when is_integer(user_id) and is_binary(emoji) do
    with %Message{} = message <- Repo.get(Message, message_id),
         true <- MessagePolicy.visible?(user_id, message) do
      case Repo.get_by(MessageReaction, message_id: message.id, user_id: user_id, emoji: emoji) do
        %MessageReaction{} = reaction -> {:ok, reaction}
        nil -> Elektrine.Messaging.add_reaction(message.id, user_id, emoji)
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def add_status_reaction(_user_id, _message_id, _emoji), do: {:error, :not_found}

  def remove_status_reaction(user_id, message_id, emoji)
      when is_integer(user_id) and is_binary(emoji) do
    with %Message{} = message <- Repo.get(Message, message_id),
         true <- MessagePolicy.visible?(user_id, message) do
      Elektrine.Messaging.remove_reaction(message.id, user_id, emoji)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def remove_status_reaction(_user_id, _message_id, _emoji), do: {:error, :not_found}
end
