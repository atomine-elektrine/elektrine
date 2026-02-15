defmodule Mix.Tasks.Badge.Grant do
  @moduledoc """
  Grants a badge to a user.

  Usage:
      mix badge.grant USERNAME BADGE_TYPE [GRANTED_BY_USERNAME]

  Badge types:
  - staff
  - verified
  - admin
  - moderator
  - supporter
  - developer
  - contributor
  - beta_tester

  Examples:
      mix badge.grant alice staff admin
      mix badge.grant bob verified admin
  """
  @shortdoc "Grants a badge to a user"

  use Mix.Task
  import Ecto.Query
  alias Elektrine.{Repo, Accounts, Profiles}

  @requirements ["app.repo"]

  @impl Mix.Task
  def run([username, badge_type | rest]) do
    granted_by_username = List.first(rest)

    case Accounts.get_user_by_username(username) do
      nil ->
        Mix.shell().error("User not found: #{username}")
        System.halt(1)

      user ->
        # Get admin user who's granting the badge
        granted_by_id =
          if granted_by_username do
            case Accounts.get_user_by_username(granted_by_username) do
              nil ->
                Mix.shell().error("Admin user not found: #{granted_by_username}")
                System.halt(1)

              admin ->
                if admin.is_admin do
                  admin.id
                else
                  Mix.shell().error("User #{granted_by_username} is not an admin")
                  System.halt(1)
                end
            end
          else
            # Default to first admin user
            admin = Repo.one(from(u in Accounts.User, where: u.is_admin == true, limit: 1))

            if admin do
              admin.id
            else
              Mix.shell().error("No admin user found in database")
              System.halt(1)
            end
          end

        # Check if badge already exists
        if Profiles.has_badge?(user.id, badge_type) do
          Mix.shell().info("User #{username} already has a #{badge_type} badge")
        else
          case Profiles.grant_badge(user.id, badge_type, granted_by_id) do
            {:ok, badge} ->
              Mix.shell().info("✓ Successfully granted #{badge_type} badge to #{username}")
              Mix.shell().info("  Badge: #{badge.badge_text}")
              Mix.shell().info("  Color: #{badge.badge_color}")
              Mix.shell().info("  Icon: #{badge.badge_icon}")

            {:error, changeset} ->
              Mix.shell().error("Failed to grant badge:")
              Mix.shell().error(inspect(changeset.errors))
              System.halt(1)
          end
        end
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix badge.grant USERNAME BADGE_TYPE [GRANTED_BY_USERNAME]")
    Mix.shell().info("\nAvailable badge types:")
    Mix.shell().info("  - staff")
    Mix.shell().info("  - verified")
    Mix.shell().info("  - admin")
    Mix.shell().info("  - moderator")
    Mix.shell().info("  - supporter")
    Mix.shell().info("  - developer")
    Mix.shell().info("  - contributor")
    Mix.shell().info("  - beta_tester")
    System.halt(1)
  end
end
