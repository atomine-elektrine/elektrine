defmodule Elektrine.Accounts.AccountImportWorker do
  @moduledoc """
  Imports follow, mute, block, and domain-block relationships from identifiers.
  """
  use Oban.Worker, queue: :default, max_attempts: 3, priority: 8

  require Logger

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles

  @types ~w(follow mute block domain_block)
  @max_identifiers 5_000

  def max_identifiers, do: @max_identifiers

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "type" => type, "identifier" => identifier}
      })
      when type in @types do
    case perform_import(user_id, type, identifier) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Account import #{type} failed for #{inspect(identifier)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_import_job}

  def enqueue_many(user_id, type, identifiers) when type in @types and is_list(identifiers) do
    identifiers =
      identifiers
      |> normalize_identifiers()

    if length(identifiers) > @max_identifiers do
      {:error, :too_many_import_identifiers}
    else
      jobs =
        Enum.map(identifiers, fn identifier ->
          %{user_id: user_id, type: type, identifier: identifier}
          |> new()
          |> Oban.insert()
        end)

      {:ok, jobs}
    end
  end

  def enqueue_many(_user_id, _type, _identifiers), do: {:error, :invalid_import_type}

  defp normalize_identifiers(identifiers) do
    identifiers
    |> Enum.map(&normalize_identifier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp perform_import(user_id, "follow", identifier) do
    with {:ok, target} <- resolve_target(identifier) do
      case target do
        {:user, target_user_id} ->
          normalize_idempotent(Profiles.follow_user(user_id, target_user_id))

        {:remote_actor, actor_id} ->
          normalize_idempotent(Profiles.follow_remote_actor(user_id, actor_id))
      end
    end
  end

  defp perform_import(user_id, "mute", identifier) do
    with {:ok, target} <- resolve_target(identifier) do
      case target do
        {:user, target_user_id} ->
          normalize_idempotent(Accounts.mute_user(user_id, target_user_id))

        {:remote_actor, actor_id} ->
          normalize_idempotent(Accounts.mute_remote_actor(user_id, actor_id))
      end
    end
  end

  defp perform_import(user_id, "block", identifier) do
    with {:ok, target} <- resolve_target(identifier) do
      case target do
        {:user, target_user_id} ->
          normalize_idempotent(Accounts.block_user(user_id, target_user_id))

        {:remote_actor, actor_id} ->
          normalize_idempotent(Accounts.block_remote_actor(user_id, actor_id))
      end
    end
  end

  defp perform_import(user_id, "domain_block", identifier) do
    normalize_idempotent(Accounts.block_domain(user_id, normalize_identifier(identifier)))
  end

  defp resolve_target(identifier) do
    case resolve_local_user(identifier) do
      {:ok, user} -> {:ok, {:user, user.id}}
      {:error, :not_found} -> resolve_remote_actor(identifier)
    end
  end

  defp resolve_local_user(identifier) do
    identifier
    |> normalize_identifier()
    |> local_part()
    |> case do
      nil ->
        {:error, :not_found}

      local ->
        case Accounts.get_user_by_username_or_handle(local) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end
    end
  end

  defp resolve_remote_actor(identifier) do
    with acct when is_binary(acct) <- normalize_identifier(identifier) do
      acct = String.trim_leading(acct, "@")

      if actor_uri?(acct) do
        resolve_remote_actor_uri(acct)
      else
        resolve_remote_actor_account(acct)
      end
    end
  end

  defp resolve_remote_actor_uri(uri) do
    case ActivityPub.get_actor_by_uri(uri) do
      %Actor{} = actor ->
        {:ok, {:remote_actor, actor.id}}

      nil ->
        case ActivityPub.get_or_fetch_actor(uri) do
          {:ok, %Actor{} = actor} -> {:ok, {:remote_actor, actor.id}}
          _ -> {:error, :not_found}
        end
    end
  end

  defp resolve_remote_actor_account(acct) do
    case cached_remote_actor(acct) do
      %Actor{} = actor ->
        {:ok, {:remote_actor, actor.id}}

      nil ->
        with {:ok, actor_uri} <- ActivityPub.webfinger_lookup(acct),
             {:ok, %Actor{} = actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
          {:ok, {:remote_actor, actor.id}}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp actor_uri?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp cached_remote_actor(acct) do
    case String.split(acct, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" ->
        ActivityPub.get_actor_by_username_and_domain(username, domain)

      _ ->
        nil
    end
  end

  defp local_part(identifier) when is_binary(identifier) do
    trimmed = String.trim_leading(identifier, "@")
    local_domains = MapSet.new([String.downcase(ActivityPub.instance_domain())])

    case String.split(trimmed, "@", parts: 2) do
      [name] ->
        name

      [name, domain] ->
        if MapSet.member?(local_domains, String.downcase(domain)), do: name, else: nil
    end
  end

  defp local_part(_), do: nil

  defp normalize_identifier(nil), do: nil

  defp normalize_identifier(identifier) when is_binary(identifier) do
    identifier
    |> strip_utf8_bom()
    |> String.trim()
    |> String.trim_leading("acct:")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_identifier(_), do: nil

  defp strip_utf8_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_utf8_bom(value), do: value

  defp normalize_idempotent({:ok, _}), do: :ok
  defp normalize_idempotent({:error, :already_following}), do: :ok
  defp normalize_idempotent({:error, changeset = %Ecto.Changeset{}}), do: {:error, changeset}
  defp normalize_idempotent({:error, reason}), do: {:error, reason}
  defp normalize_idempotent(_), do: :ok
end
