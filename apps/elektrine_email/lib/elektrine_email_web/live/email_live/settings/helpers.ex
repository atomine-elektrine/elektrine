defmodule ElektrineEmailWeb.EmailLive.Settings.Helpers do
  @moduledoc """
  Helpers shared across the email settings domain modules.
  """

  alias ElektrineEmailWeb.UserErrorHelpers

  def get_changeset_error(changeset) do
    UserErrorHelpers.join_changeset_errors(changeset,
      fallback: "Please review the form and try again."
    )
  end
end
