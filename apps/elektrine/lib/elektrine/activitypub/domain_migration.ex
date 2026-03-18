defmodule Elektrine.ActivityPub.DomainMigration do
  @moduledoc """
  Helpers for ActivityPub domain migration (Move activities).
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Builder, Publisher}
  alias Elektrine.Domains
  alias Elektrine.Repo

  @doc """
  Broadcasts Move activities to remote follower inboxes.

  ## Options
    * `:from_domain` - legacy domain to move from (defaults to `ACTIVITYPUB_MOVE_FROM_DOMAIN`)
    * `:to_domain` - target domain to move to (defaults to current `INSTANCE_DOMAIN`)
    * `:dry_run` - if true, only computes counts without delivering
    * `:usernames` - optional list of usernames to migrate
    * `:limit` - optional max number of users
  """
  def broadcast_moves(opts \\ []) do
    with {:ok, from_domain} <- resolve_from_domain(opts),
         {:ok, to_domain} <- resolve_to_domain(opts),
         :ok <- validate_domain_pair(from_domain, to_domain) do
      users = users_for_migration(opts)
      dry_run = Keyword.get(opts, :dry_run, false)
      from_base_url = ActivityPub.instance_url_for_domain(from_domain)
      to_base_url = ActivityPub.instance_url_for_domain(to_domain)

      summary =
        Enum.reduce(users, initial_summary(from_domain, to_domain, dry_run), fn user, acc ->
          old_actor_uri = ActivityPub.actor_uri(user, from_base_url)
          new_actor_uri = ActivityPub.actor_uri(user, to_base_url)
          move_activity = Builder.build_move_activity(user, old_actor_uri, new_actor_uri)
          inboxes = Publisher.get_follower_inboxes(user.id) |> Enum.uniq()

          acc = %{acc | users_processed: acc.users_processed + 1}

          cond do
            inboxes == [] ->
              %{acc | users_without_remote_followers: acc.users_without_remote_followers + 1}

            dry_run ->
              %{acc | deliveries_attempted: acc.deliveries_attempted + length(inboxes)}

            true ->
              deliver_move(user, move_activity, inboxes, from_base_url, acc)
          end
        end)

      {:ok, summary}
    end
  end

  defp resolve_from_domain(opts) do
    case normalize_domain(Keyword.get(opts, :from_domain, Domains.activitypub_move_from_domain())) do
      nil -> {:error, :missing_from_domain}
      domain -> {:ok, domain}
    end
  end

  defp resolve_to_domain(opts) do
    case normalize_domain(Keyword.get(opts, :to_domain, ActivityPub.instance_domain())) do
      nil -> {:error, :missing_to_domain}
      domain -> {:ok, domain}
    end
  end

  defp validate_domain_pair(from_domain, to_domain) when from_domain == to_domain do
    {:error, :same_domain}
  end

  defp validate_domain_pair(_, _), do: :ok

  defp users_for_migration(opts) do
    usernames =
      opts
      |> Keyword.get(:usernames, [])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    limit = Keyword.get(opts, :limit)

    base_query =
      from(u in User,
        where:
          u.activitypub_enabled == true and not is_nil(u.activitypub_private_key) and
            not is_nil(u.activitypub_public_key),
        order_by: [asc: u.id]
      )

    scoped_query =
      if usernames == [] do
        base_query
      else
        from(u in base_query, where: u.username in ^usernames)
      end

    limited_query =
      case limit do
        value when is_integer(value) and value > 0 ->
          from(u in scoped_query, limit: ^value)

        _ ->
          scoped_query
      end

    Repo.all(limited_query)
  end

  defp deliver_move(user, move_activity, inboxes, from_base_url, acc) do
    Enum.reduce(inboxes, acc, fn inbox_url, current ->
      current = %{current | deliveries_attempted: current.deliveries_attempted + 1}

      case Publisher.deliver(move_activity, user, inbox_url, key_id_base_url: from_base_url) do
        {:ok, :delivered} ->
          %{current | deliveries_succeeded: current.deliveries_succeeded + 1}

        {:error, reason} ->
          %{
            current
            | deliveries_failed: current.deliveries_failed + 1,
              errors: [
                %{
                  username: user.username,
                  inbox: inbox_url,
                  reason: inspect(reason)
                }
                | current.errors
              ]
          }
      end
    end)
  end

  defp initial_summary(from_domain, to_domain, dry_run) do
    %{
      from_domain: from_domain,
      to_domain: to_domain,
      dry_run: dry_run,
      users_processed: 0,
      users_without_remote_followers: 0,
      deliveries_attempted: 0,
      deliveries_succeeded: 0,
      deliveries_failed: 0,
      errors: []
    }
  end

  defp normalize_domain(domain) when is_binary(domain) do
    case domain |> String.trim() |> String.downcase() do
      "" -> nil
      value -> value
    end
  end

  defp normalize_domain(_), do: nil
end
