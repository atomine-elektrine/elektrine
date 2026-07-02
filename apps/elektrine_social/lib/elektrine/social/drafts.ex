defmodule Elektrine.Social.Drafts do
  @moduledoc "Context for managing post drafts.\nAllows users to save, edit, and publish draft posts.\n"
  import Ecto.Changeset
  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.{Conversation, Message}
  alias Elektrine.Social.HashtagExtractor

  @default_min_schedule_offset_seconds 300
  @default_daily_schedule_limit 25
  @default_total_schedule_limit 300
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

  @doc "Lists scheduled drafts for Mastodon-compatible scheduled status APIs."
  def list_scheduled_drafts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.sender_id == ^user_id and m.is_draft == true and c.type == "timeline" and
          not is_nil(m.scheduled_at) and is_nil(m.deleted_at),
      order_by: [asc: m.scheduled_at, asc: m.id],
      limit: ^limit,
      preload: [:link_preview, :hashtags]
    )
    |> Repo.all()
  end

  @doc "Lists scheduled drafts that are due to publish."
  def list_due_scheduled_drafts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.is_draft == true and c.type == "timeline" and not is_nil(m.scheduled_at) and
          m.scheduled_at <= ^now and is_nil(m.deleted_at),
      order_by: [asc: m.scheduled_at, asc: m.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Publishes scheduled drafts whose scheduled time has arrived."
  def publish_due_scheduled_drafts(opts \\ []) do
    opts
    |> list_due_scheduled_drafts()
    |> Enum.reduce(%{published: 0, failed: 0}, fn draft, acc ->
      case publish_draft(draft.id, draft.sender_id) do
        {:ok, _post} -> %{acc | published: acc.published + 1}
        {:error, _reason} -> %{acc | failed: acc.failed + 1}
      end
    end)
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

  @doc "Gets a scheduled draft by ID."
  def get_scheduled_draft(draft_id, user_id) do
    case get_draft(draft_id, user_id) do
      %Message{scheduled_at: %DateTime{}} = draft -> draft
      _ -> nil
    end
  end

  @doc "Saves a new draft or updates an existing one.\n\n## Options\n  * `:content` - The post content\n  * `:title` - Optional title\n  * `:visibility` - Post visibility (defaults to \"followers\")\n  * `:media_urls` - List of media URLs\n  * `:alt_texts` - Map of media alt texts\n  * `:content_warning` - Optional content warning\n  * `:sensitive` - Whether media/content should be treated as sensitive\n  * `:category` - Gallery category\n"
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
    base_media_metadata = Keyword.get(opts, :media_metadata, %{})
    alt_texts = Keyword.get(opts, :alt_texts, %{})
    content_warning = Keyword.get(opts, :content_warning)
    sensitive = Keyword.get(opts, :sensitive, false)
    scheduled_at = Keyword.get(opts, :scheduled_at)
    category = Keyword.get(opts, :category)
    post_type = Keyword.get(opts, :post_type, "post")
    timeline_conversation = Social.get_or_create_user_timeline(user_id)

    media_metadata =
      if Enum.empty?(media_urls) do
        %{}
      else
        Social.merge_post_media_metadata(base_media_metadata, alt_texts)
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
      sensitive: sensitive,
      category: category,
      is_draft: true,
      scheduled_at: scheduled_at
    }

    %Message{}
    |> Message.changeset(attrs)
    |> validate_schedule_limits(user_id)
    |> Repo.insert()
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
        base_media_metadata = Keyword.get(opts, :media_metadata, draft.media_metadata || %{})

        alt_texts =
          Keyword.get(
            opts,
            :alt_texts,
            Map.get(draft.media_metadata || %{}, "alt_texts") ||
              Map.get(draft.media_metadata || %{}, :alt_texts) ||
              %{}
          )

        content_warning = Keyword.get(opts, :content_warning, draft.content_warning)
        sensitive = Keyword.get(opts, :sensitive, draft.sensitive)
        scheduled_at = Keyword.get(opts, :scheduled_at, draft.scheduled_at)
        category = Keyword.get(opts, :category, draft.category)

        media_metadata =
          if Enum.empty?(media_urls) do
            %{}
          else
            Social.merge_post_media_metadata(base_media_metadata, alt_texts)
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
          sensitive: sensitive,
          category: category,
          scheduled_at: scheduled_at
        }

        draft
        |> Message.changeset(attrs)
        |> maybe_validate_updated_schedule(draft, opts)
        |> Repo.update()
    end
  end

  @doc "Updates a scheduled draft while preserving scheduled-status semantics."
  def update_scheduled_draft(draft_id, user_id, opts) do
    case get_scheduled_draft(draft_id, user_id) do
      nil -> {:error, :not_found}
      _draft -> update_draft(draft_id, user_id, opts)
    end
  end

  @doc "Publishes a draft, converting it to a regular post.\nValidates the draft has content before publishing.\n"
  def publish_draft(draft_id, user_id) do
    case get_draft(draft_id, user_id) do
      nil ->
        {:error, :not_found}

      draft ->
        has_content = Elektrine.Strings.present?(draft.content)
        has_media = draft.media_urls && draft.media_urls != []

        cond do
          scheduled_for_future?(draft.scheduled_at) ->
            {:error, :scheduled_for_future}

          !has_content && !has_media ->
            {:error, :empty_draft}

          true ->
            now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

            result =
              draft
              |> change(%{is_draft: false, scheduled_at: nil, inserted_at: now, updated_at: now})
              |> Repo.update()

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
                  Elektrine.Async.start(fn ->
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

  defp scheduled_for_future?(nil), do: false

  defp scheduled_for_future?(%DateTime{} = scheduled_at) do
    DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt
  end

  defp maybe_validate_updated_schedule(changeset, draft, opts) do
    if Keyword.has_key?(opts, :scheduled_at) do
      validate_schedule_limits(changeset, draft.sender_id, draft.id)
    else
      changeset
    end
  end

  defp validate_schedule_limits(changeset, user_id, current_draft_id \\ nil) do
    scheduled_at = get_field(changeset, :scheduled_at)

    cond do
      is_nil(scheduled_at) ->
        changeset

      not far_enough?(scheduled_at) ->
        add_error(
          changeset,
          :scheduled_at,
          "must be at least #{min_schedule_offset_seconds()} seconds from now"
        )

      exceeds_daily_schedule_limit?(user_id, scheduled_at, current_draft_id) ->
        add_error(changeset, :scheduled_at, "daily limit exceeded")

      exceeds_total_schedule_limit?(user_id, current_draft_id) ->
        add_error(changeset, :scheduled_at, "total limit exceeded")

      true ->
        changeset
    end
  end

  defp far_enough?(%DateTime{} = scheduled_at) do
    DateTime.diff(scheduled_at, DateTime.utc_now(), :second) >= min_schedule_offset_seconds()
  end

  defp far_enough?(_scheduled_at), do: false

  defp exceeds_daily_schedule_limit?(user_id, scheduled_at, current_draft_id) do
    scheduled_date = DateTime.to_date(scheduled_at)

    count =
      base_scheduled_limit_query(user_id, current_draft_id)
      |> where([m], fragment("?::date = ?", m.scheduled_at, ^scheduled_date))
      |> Repo.aggregate(:count, :id)

    count >= daily_schedule_limit()
  end

  defp exceeds_total_schedule_limit?(user_id, current_draft_id) do
    user_id
    |> base_scheduled_limit_query(current_draft_id)
    |> Repo.aggregate(:count, :id)
    |> Kernel.>=(total_schedule_limit())
  end

  defp base_scheduled_limit_query(user_id, current_draft_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.sender_id == ^user_id and m.is_draft == true and c.type == "timeline" and
            not is_nil(m.scheduled_at) and m.scheduled_at > ^now and is_nil(m.deleted_at)
      )

    if current_draft_id do
      from(m in query, where: m.id != ^current_draft_id)
    else
      query
    end
  end

  defp min_schedule_offset_seconds do
    schedule_config(:min_offset_seconds, @default_min_schedule_offset_seconds)
  end

  defp daily_schedule_limit do
    schedule_config(:daily_user_limit, @default_daily_schedule_limit)
  end

  defp total_schedule_limit do
    schedule_config(:total_user_limit, @default_total_schedule_limit)
  end

  defp schedule_config(key, default) do
    :elektrine_social
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
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
