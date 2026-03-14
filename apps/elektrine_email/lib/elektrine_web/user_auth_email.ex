defmodule ElektrineWeb.UserAuthEmail do
  @moduledoc """
  Email-owned authentication helpers used by the shared shell.
  """

  alias Elektrine.AppCache
  alias Elektrine.Email.Cached, as: EmailCached

  def warm_user_caches(user) do
    case Elektrine.Email.get_user_mailbox(user.id) do
      nil ->
        :ok

      mailbox ->
        EmailCached.warm_user_cache(user.id, mailbox.id)
        AppCache.warm_user_cache(user.id, mailbox.id)
    end
  end
end
