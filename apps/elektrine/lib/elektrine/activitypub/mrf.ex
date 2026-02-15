defmodule Elektrine.ActivityPub.MRF do
  @moduledoc """
  Message Rewrite Facility (MRF) for ActivityPub federation.

  MRF is a policy-based system for filtering, modifying, or rejecting
  incoming ActivityPub activities. Policies are applied in order and
  can transform or reject activities before they are processed.

  ## Configuration

      config :elektrine, :mrf,
        policies: [
          Elektrine.ActivityPub.MRF.SimplePolicy
        ],
        transparency: true

  ## Built-in Policies

  - `SimplePolicy` - Domain-based accept/reject, media removal, NSFW marking
  - `KeywordPolicy` - Filters based on content keywords
  - `DropPolicy` - Drops all activities (for testing)
  - `NoOpPolicy` - Passes all activities through (default)
  """

  require Logger

  @doc """
  Filters an activity through all configured MRF policies.

  Returns `{:ok, activity}` if the activity passes all policies,
  or `{:reject, reason}` if any policy rejects it.
  """
  def filter(activity) when is_map(activity) do
    policies = get_policies()

    Enum.reduce_while(policies, {:ok, activity}, fn policy, {:ok, acc} ->
      case filter_one(policy, acc) do
        {:ok, filtered} -> {:cont, {:ok, filtered}}
        {:reject, reason} -> {:halt, {:reject, reason}}
      end
    end)
  end

  @doc """
  Filters an activity through a single policy.
  """
  def filter_one(policy, activity) do
    # Don't filter Undo, Block, or Delete through most policies
    # These should generally be processed to maintain consistency
    activity_type = activity["type"]

    if activity_type in ["Undo", "Block", "Delete"] and
         policy != Elektrine.ActivityPub.MRF.SimplePolicy do
      {:ok, activity}
    else
      try do
        policy.filter(activity)
      rescue
        e ->
          Logger.error("MRF policy #{inspect(policy)} crashed: #{inspect(e)}")
          {:ok, activity}
      end
    end
  end

  @doc """
  Gets the list of configured MRF policies.
  """
  def get_policies do
    configured = Application.get_env(:elektrine, :mrf, [])[:policies] || []

    # Always include these core policies at the end
    core_policies = [
      Elektrine.ActivityPub.MRF.NormalizePolicy
    ]

    (List.wrap(configured) ++ core_policies)
    |> Enum.uniq()
  end

  @doc """
  Describes the current MRF configuration.
  Used for transparency in nodeinfo.
  """
  def describe do
    policies = get_policies()

    policy_configs =
      Enum.reduce(policies, %{}, fn policy, acc ->
        case policy.describe() do
          {:ok, config} -> Map.merge(acc, config)
          _ -> acc
        end
      end)

    policy_names =
      policies
      |> Enum.map(fn policy ->
        policy
        |> to_string()
        |> String.split(".")
        |> List.last()
      end)

    transparency = Application.get_env(:elektrine, :mrf, [])[:transparency] || false

    {:ok,
     %{
       mrf_policies: policy_names,
       transparency: transparency
     }
     |> Map.merge(if(transparency, do: policy_configs, else: %{}))}
  end

  @doc """
  Checks if a domain matches any in a list of domains/patterns.
  Supports wildcard patterns like "*.example.com".
  """
  def subdomain_match?(patterns, host) when is_list(patterns) do
    Enum.any?(patterns, fn pattern ->
      subdomain_match_one?(pattern, host)
    end)
  end

  defp subdomain_match_one?(pattern, host) do
    cond do
      # Exact match
      pattern == host ->
        true

      # Wildcard subdomain match: *.example.com matches foo.example.com
      String.starts_with?(pattern, "*.") ->
        base = String.trim_leading(pattern, "*.")
        host == base or String.ends_with?(host, "." <> base)

      # No match
      true ->
        false
    end
  end

  @doc """
  Extracts the host from an actor URI or activity.
  """
  def get_actor_host(%{"actor" => actor}) when is_binary(actor) do
    URI.parse(actor).host
  end

  def get_actor_host(%{"id" => id}) when is_binary(id) do
    URI.parse(id).host
  end

  def get_actor_host(uri) when is_binary(uri) do
    URI.parse(uri).host
  end

  def get_actor_host(_), do: nil
end
