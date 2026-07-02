defmodule Elektrine.Social.ExpiredDataCleanupWorker do
  @moduledoc """
  Prunes expired social/auth support rows that don't need permanent retention.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, priority: 9

  alias Elektrine.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_preview_cutoff = DateTime.add(now, -30, :day)
    revoked_token_cutoff = DateTime.add(now, -30, :day)

    prune_expired_api_tokens(now, revoked_token_cutoff)
    prune_expired_oauth_tokens(now)
    prune_expired_social_filters(now)
    prune_stale_failed_link_previews(stale_preview_cutoff)

    :ok
  end

  defp prune_expired_api_tokens(now, revoked_cutoff) do
    Repo.query!(
      """
      delete from api_tokens
      where (expires_at is not null and expires_at < $1)
         or (revoked_at is not null and revoked_at < $2)
      """,
      [now, revoked_cutoff]
    )
  end

  defp prune_expired_oauth_tokens(now) do
    Repo.query!("delete from oauth_tokens where valid_until < $1", [now])
  end

  defp prune_expired_social_filters(now) do
    Repo.query!(
      """
      delete from social_filters
      where expires_at is not null
        and expires_at < $1
      """,
      [now]
    )
  end

  defp prune_stale_failed_link_previews(cutoff) do
    Repo.query!(
      """
      delete from link_previews
      where status = 'failed'
        and fetched_at is not null
        and fetched_at < $1
      """,
      [cutoff]
    )
  end
end
