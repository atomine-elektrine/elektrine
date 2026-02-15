defmodule Mix.Tasks.Badge.Revoke do
  @moduledoc """
  Revokes a badge from a user.

  Usage:
      mix badge.revoke USERNAME BADGE_TYPE

  Examples:
      mix badge.revoke alice staff
      mix badge.revoke bob verified
  """
  @shortdoc "Revokes a badge from a user"

  use Mix.Task
  alias Elektrine.{Accounts, Profiles}

  @requirements ["app.repo"]

  @impl Mix.Task
  def run([username, badge_type]) do
    case Accounts.get_user_by_username(username) do
      nil ->
        Mix.shell().error("User not found: #{username}")
        System.halt(1)

      user ->
        if Profiles.has_badge?(user.id, badge_type) do
          {count, _} = Profiles.revoke_badge(user.id, badge_type)
          Mix.shell().info("✓ Revoked #{count} #{badge_type} badge(s) from #{username}")
        else
          Mix.shell().info("User #{username} does not have a #{badge_type} badge")
        end
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix badge.revoke USERNAME BADGE_TYPE")
    System.halt(1)
  end
end
