defmodule Elektrine.ActivityPub.DomainMigration do
  @moduledoc """
  Helpers for ActivityPub domain migration (Move activities).
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Actor, Builder, Publisher}
  alias Elektrine.Domains
  alias Elektrine.Repo

  @doc """
  Verifies, stores, and broadcasts a single local account move.
  """
  def move_account(user, target_account, opts \\ [])

  def move_account(%User{} = user, target_account, opts) when is_binary(target_account) do
    with {:ok, target_actor} <- resolve_move_target_actor(target_account, opts),
         old_actor_uri <- ActivityPub.actor_uri(user),
         :ok <- validate_target_alias(target_actor, old_actor_uri),
         {:ok, updated_user} <- Accounts.update_user(user, %{moved_to: target_actor.uri}),
         {:ok, summary} <- broadcast_account_move(updated_user, target_actor.uri, opts) do
      {:ok, Map.put(summary, :user, updated_user)}
    end
  end

  def move_account(%User{}, _target_account, _opts), do: {:error, :invalid_move_target}

  @doc """
  Broadcasts a Move activity for an already-verified local account move.
  """
  def broadcast_account_move(user, target_actor_uri, opts \\ [])

  def broadcast_account_move(%User{} = user, target_actor_uri, opts)
      when is_binary(target_actor_uri) do
    old_actor_uri = ActivityPub.actor_uri(user)
    move_activity = Builder.build_move_activity(user, old_actor_uri, target_actor_uri)
    inboxes = Publisher.get_follower_inboxes(user.id) |> Enum.uniq()

    if Keyword.get(opts, :dry_run, false) do
      {:ok,
       %{
         activity: nil,
         target_actor_uri: target_actor_uri,
         old_actor_uri: old_actor_uri,
         deliveries_queued: length(inboxes),
         dry_run: true
       }}
    else
      with {:ok, activity_record} <- Publisher.publish(move_activity, user, inboxes) do
        {:ok,
         %{
           activity: activity_record,
           target_actor_uri: target_actor_uri,
           old_actor_uri: old_actor_uri,
           deliveries_queued: length(inboxes),
           dry_run: false
         }}
      end
    end
  end

  def broadcast_account_move(%User{}, _target_actor_uri, _opts),
    do: {:error, :invalid_move_target}

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

  defp resolve_move_target_actor(target_account, opts) do
    case normalize_target_account(target_account) do
      nil ->
        {:error, :invalid_move_target}

      {:uri, actor_uri} ->
        resolve_actor_uri(actor_uri, opts)

      {:acct, acct} ->
        resolve_acct_actor(acct, opts)
    end
  end

  defp normalize_target_account(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.starts_with?(value, ["http://", "https://"]) ->
        {:uri, value}

      String.starts_with?(value, "acct:") ->
        value |> String.trim_leading("acct:") |> normalize_acct_target()

      String.contains?(value, "@") ->
        normalize_acct_target(value)

      true ->
        nil
    end
  end

  defp normalize_target_account(_), do: nil

  defp normalize_acct_target(acct) do
    acct =
      acct
      |> String.trim()
      |> String.trim_leading("@")

    case String.split(acct, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" -> {:acct, "#{username}@#{domain}"}
      _ -> nil
    end
  end

  defp resolve_actor_uri(actor_uri, _opts) do
    case ActivityPub.get_actor_by_uri(actor_uri) do
      %Actor{} = actor ->
        {:ok, actor}

      nil ->
        ActivityPub.get_or_fetch_actor(actor_uri)
    end
  end

  defp resolve_acct_actor(acct, opts) do
    with {:ok, {username, domain}} <- split_acct(acct) do
      case get_actor_by_handle(username, domain) do
        %Actor{} = actor ->
          {:ok, actor}

        nil ->
          with {:ok, actor_uri} <- ActivityPub.webfinger_lookup(acct, opts) do
            resolve_actor_uri(actor_uri, opts)
          end
      end
    end
  end

  defp split_acct(acct) when is_binary(acct) do
    case String.split(acct, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" -> {:ok, {username, domain}}
      _ -> {:error, :invalid_move_target}
    end
  end

  defp get_actor_by_handle(username, domain) do
    from(a in Actor,
      where:
        fragment("LOWER(?)", a.username) == ^String.downcase(username) and
          fragment("LOWER(?)", a.domain) == ^String.downcase(domain),
      order_by: [asc: a.inserted_at, asc: a.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp validate_target_alias(%Actor{} = target_actor, old_actor_uri)
       when is_binary(old_actor_uri) do
    aliases =
      target_actor.metadata
      |> extract_uri_candidates("alsoKnownAs")
      |> Enum.map(&normalize_uri/1)

    if normalize_uri(old_actor_uri) in aliases do
      :ok
    else
      {:error, :move_target_not_verified}
    end
  end

  defp validate_target_alias(_, _), do: {:error, :move_target_not_verified}

  defp extract_uri_candidates(metadata, field) when is_map(metadata) do
    metadata
    |> Map.get(field)
    |> expand_uri_candidates()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_uri_candidates(_metadata, _field), do: []

  defp expand_uri_candidates(value) when is_binary(value), do: [value]

  defp expand_uri_candidates(values) when is_list(values),
    do: Enum.flat_map(values, &expand_uri_candidates/1)

  defp expand_uri_candidates(%{"id" => id}) when is_binary(id), do: [id]
  defp expand_uri_candidates(%{"href" => href}) when is_binary(href), do: [href]
  defp expand_uri_candidates(%{"url" => url}) when is_binary(url), do: [url]
  defp expand_uri_candidates(_), do: []

  defp normalize_uri(uri) when is_binary(uri),
    do:
      uri
      |> String.trim()
      |> String.split("#", parts: 2)
      |> hd()
      |> String.split("?", parts: 2)
      |> hd()
      |> String.trim_trailing("/")
end
