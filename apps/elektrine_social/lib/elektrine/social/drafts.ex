defmodule Elektrine.Social.Drafts do
  @moduledoc "Context for managing post drafts.\nAllows users to save, edit, and publish draft posts.\n"
  import Ecto.Query, warn: false
  alias Elektrine.Messaging.{Conversation, Message}
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.HashtagExtractor
  @doc "Lists all drafts for a user.\nReturns drafts ordered by most recently updated first.\n"
  def list_drafts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.sender_id == ^user_id and m.is_draft == true and c.type == "timeline" and
          is_nil(m.deleted_at),
      order_by: [desc: m.updated_at],
      limit: ^limit,
      preload: [:link_preview, :hashtags]
    )
    |> Repo.all()
  end

  @doc "Gets a single draft by ID.\nReturns nil if not found or not owned by user.\n"
  def get_draft(draft_id, user_id) do
    from(m in Message,
      where:
        m.id == ^draft_id and m.sender_id == ^user_id and m.is_draft == true and
          is_nil(m.deleted_at),
      preload: [:link_preview, :hashtags, sender: [:profile]]
    )
    |> Repo.one()
  end

  @doc "Saves a new draft or updates an existing one.\n\n## Options\n  * `:content` - The post content\n  * `:title` - Optional title\n  * `:visibility` - Post visibility (defaults to \"followers\")\n  * `:media_urls` - List of media URLs\n  * `:alt_texts` - Map of media alt texts\n  * `:content_warning` - Optional content warning\n  * `:category` - Gallery category\n"
  def save_draft(user_id, opts \\ []) do
    draft_id = Keyword.get(opts, :draft_id)

    if draft_id do
      update_draft(draft_id, user_id, opts)
    else
      create_draft(user_id, opts)
    end
  end

  @doc "Creates a new draft.\n"
  def create_draft(user_id, opts \\ []) do
    content = Keyword.get(opts, :content, "")
    title = Keyword.get(opts, :title)
    visibility = Keyword.get(opts, :visibility, "followers")
    media_urls = Keyword.get(opts, :media_urls, [])
    alt_texts = Keyword.get(opts, :alt_texts, %{})
    content_warning = Keyword.get(opts, :content_warning)
    category = Keyword.get(opts, :category)
    post_type = Keyword.get(opts, :post_type, "post")
    timeline_conversation = Social.get_or_create_user_timeline(user_id)

    media_metadata =
      if Enum.empty?(alt_texts) do
        %{}
      else
        %{"alt_texts" => alt_texts}
      end

    attrs = %{
      conversation_id: timeline_conversation.id,
      sender_id: user_id,
      content: content,
      title: title,
      message_type:
        if Enum.empty?(media_urls) do
          "text"
        else
          "image"
        end,
      media_urls: media_urls,
      media_metadata: media_metadata,
      visibility: visibility,
      post_type: post_type,
      content_warning: content_warning,
      category: category,
      is_draft: true
    }

    %Message{} |> Message.changeset(attrs) |> Repo.insert()
  end

  @doc "Updates an existing draft.\n"
  def update_draft(draft_id, user_id, opts) do
    case get_draft(draft_id, user_id) do
      nil ->
        {:error, :not_found}

      draft ->
        content = Keyword.get(opts, :content, draft.content)
        title = Keyword.get(opts, :title, draft.title)
        visibility = Keyword.get(opts, :visibility, draft.visibility)
        media_urls = Keyword.get(opts, :media_urls, draft.media_urls)
        alt_texts = Keyword.get(opts, :alt_texts, draft.media_metadata["alt_texts"] || %{})
        content_warning = Keyword.get(opts, :content_warning, draft.content_warning)
        category = Keyword.get(opts, :category, draft.category)

        media_metadata =
          if Enum.empty?(alt_texts) do
            %{}
          else
            %{"alt_texts" => alt_texts}
          end

        attrs = %{
          content: content,
          title: title,
          message_type:
            if Enum.empty?(media_urls) do
              "text"
            else
              "image"
            end,
          media_urls: media_urls,
          media_metadata: media_metadata,
          visibility: visibility,
          content_warning: content_warning,
          category: category
        }

        draft |> Message.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Publishes a draft, converting it to a regular post.\nValidates the draft has content before publishing.\n"
  def publish_draft(draft_id, user_id) do
    case get_draft(draft_id, user_id) do
      nil ->
        {:error, :not_found}

      draft ->
        has_content = draft.content && String.trim(draft.content) != ""
        has_media = draft.media_urls && draft.media_urls != []

        if !has_content && !has_media do
          {:error, :empty_draft}
        else
          result = draft |> Message.changeset(%{is_draft: false}) |> Repo.update()

          case result do
            {:ok, published_post} ->
              if !Enum.empty?(draft.extracted_hashtags || []) do
                HashtagExtractor.process_hashtags_for_message(
                  published_post.id,
                  draft.extracted_hashtags
                )
              end

              if published_post.content do
                Social.notify_mentions(published_post.content, user_id, published_post.id)
              end

              Social.broadcast_timeline_post(published_post)

              if published_post.visibility in ["public", "followers"] do
                Task.start(fn ->
                  preloaded = Repo.preload(published_post, :sender)
                  Elektrine.ActivityPub.Outbox.federate_post(preloaded)
                end)
              end

              {:ok, published_post}

            error ->
              error
          end
        end
    end
  end

  @doc "Deletes a draft (soft delete).\n"
  def delete_draft(draft_id, user_id) do
    case get_draft(draft_id, user_id) do
      nil -> {:error, :not_found}
      draft -> draft |> Message.changeset(%{deleted_at: DateTime.utc_now()}) |> Repo.update()
    end
  end

  @doc "Counts user's drafts.\n"
  def count_drafts(user_id) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.sender_id == ^user_id and m.is_draft == true and c.type == "timeline" and
          is_nil(m.deleted_at),
      select: count(m.id)
    )
    |> Repo.one() || 0
  end
end
