defmodule Elektrine.Social.Views do
  @moduledoc """
  Tracks post views for analytics and recommendations.

  This module records when users view posts, enabling:
  - View count statistics
  - Recommendation algorithm inputs
  - Content engagement metrics
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Social.PostView

  @doc """
  Records that a user viewed a post.

  Used for recommendation algorithm and analytics.

  ## Options

    * `:view_duration_seconds` - How long the user viewed the post
    * `:completed` - Whether the user finished reading (scrolled to end)

  ## Examples

      iex> track_post_view(user_id, message_id)
      {:ok, %PostView{}}
      
      iex> track_post_view(user_id, message_id, view_duration_seconds: 30, completed: true)
      {:ok, %PostView{}}
  """
  def track_post_view(user_id, message_id, opts \\ []) do
    view_duration = Keyword.get(opts, :view_duration_seconds)
    completed = Keyword.get(opts, :completed, false)

    attrs = %{
      user_id: user_id,
      message_id: message_id,
      view_duration_seconds: view_duration,
      completed: completed
    }

    %PostView{}
    |> PostView.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets posts a user has viewed recently.

  ## Options

    * `:limit` - Maximum number of post IDs to return (default: 100)
    * `:days` - Number of days to look back (default: 7)

  Returns a list of message IDs, most recent first.
  """
  def get_user_viewed_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    days_ago = Keyword.get(opts, :days, 7)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days_ago * 24 * 60 * 60)

    from(v in PostView,
      where: v.user_id == ^user_id and v.inserted_at > ^cutoff,
      order_by: [desc: v.inserted_at],
      limit: ^limit,
      select: v.message_id
    )
    |> Repo.all()
  end

  @doc """
  Gets view count for a post.

  Returns the total number of unique views.
  """
  def get_post_view_count(message_id) do
    from(v in PostView,
      where: v.message_id == ^message_id,
      select: count(v.id)
    )
    |> Repo.one()
  end

  @doc """
  Checks if user has viewed a post.
  """
  def user_viewed_post?(user_id, message_id) do
    from(v in PostView,
      where: v.user_id == ^user_id and v.message_id == ^message_id
    )
    |> Repo.exists?()
  end
end
