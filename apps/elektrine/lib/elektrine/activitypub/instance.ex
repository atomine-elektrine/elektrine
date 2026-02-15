defmodule Elektrine.ActivityPub.Instance do
  @moduledoc """
  Represents a remote ActivityPub instance with MRF (Message Rewrite Facility) policies.

  ## Policy Types

  - `blocked` - Completely reject all activities from this instance (except deletes)
  - `silenced` - Accept activities but don't show in public timelines (deprecated, use federated_timeline_removal)
  - `media_removal` - Strip media attachments from posts
  - `media_nsfw` - Mark all media as sensitive/NSFW
  - `federated_timeline_removal` - Hide posts from federated timeline (but visible to followers)
  - `followers_only` - Force all posts to be followers-only visibility
  - `report_removal` - Reject Flag (report) activities
  - `avatar_removal` - Strip avatar images from actor profiles
  - `banner_removal` - Strip banner/header images from actor profiles
  - `reject_deletes` - Reject Delete activities (prevents removing content)

  ## Wildcard Domains

  Domains can include wildcards: `*.example.com` matches all subdomains of example.com.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_instances" do
    field(:domain, :string)
    field(:reason, :string)
    field(:notes, :string)
    field(:blocked_at, :utc_datetime)
    field(:policy_applied_at, :utc_datetime)

    # Core blocking policies
    field(:blocked, :boolean, default: false)
    field(:silenced, :boolean, default: false)

    # Granular MRF policies
    field(:media_removal, :boolean, default: false)
    field(:media_nsfw, :boolean, default: false)
    field(:federated_timeline_removal, :boolean, default: false)
    field(:followers_only, :boolean, default: false)
    field(:report_removal, :boolean, default: false)
    field(:avatar_removal, :boolean, default: false)
    field(:banner_removal, :boolean, default: false)
    field(:reject_deletes, :boolean, default: false)

    # Reachability tracking - when non-nil, instance is considered unreachable
    field(:unreachable_since, :utc_datetime)
    # Count of consecutive failures (for exponential backoff)
    field(:failure_count, :integer, default: 0)

    # Instance metadata (fetched via NodeInfo)
    field(:nodeinfo, :map, default: %{})
    field(:favicon, :string)
    field(:metadata_updated_at, :utc_datetime)

    belongs_to(:blocked_by, Elektrine.Accounts.User)
    belongs_to(:policy_applied_by, Elektrine.Accounts.User)

    timestamps()
  end

  @policy_fields [
    :blocked,
    :silenced,
    :media_removal,
    :media_nsfw,
    :federated_timeline_removal,
    :followers_only,
    :report_removal,
    :avatar_removal,
    :banner_removal,
    :reject_deletes
  ]

  @doc """
  Returns the list of policy field names.
  """
  def policy_fields, do: @policy_fields

  @doc false
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :domain,
      :reason,
      :notes,
      :blocked_at,
      :policy_applied_at,
      :blocked_by_id,
      :policy_applied_by_id
      | @policy_fields
    ])
    |> validate_required([:domain])
    |> validate_domain()
    |> unique_constraint(:domain)
  end

  @doc """
  Creates a changeset for applying MRF policies to an instance.
  """
  def policy_changeset(instance, attrs, admin_user_id) do
    instance
    |> cast(attrs, [:reason, :notes | @policy_fields])
    |> put_change(:policy_applied_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:policy_applied_by_id, admin_user_id)
    |> maybe_set_blocked_at(attrs)
  end

  defp maybe_set_blocked_at(changeset, attrs) do
    if attrs[:blocked] || attrs["blocked"] do
      put_change(changeset, :blocked_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      changeset
    end
  end

  defp validate_domain(changeset) do
    validate_change(changeset, :domain, fn :domain, domain ->
      # Allow wildcards like *.example.com
      domain = String.trim(domain) |> String.downcase()

      cond do
        domain == "" ->
          [domain: "cannot be blank"]

        String.contains?(domain, " ") ->
          [domain: "cannot contain spaces"]

        String.starts_with?(domain, ".") && !String.starts_with?(domain, "*.") ->
          [domain: "invalid format"]

        # Check for valid domain format (with optional wildcard prefix)
        !Regex.match?(
          ~r/^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/,
          domain
        ) ->
          [domain: "invalid domain format"]

        true ->
          []
      end
    end)
  end

  @doc """
  Checks if a given hostname matches this instance's domain pattern.
  Supports wildcard patterns like *.example.com
  """
  def matches_domain?(%__MODULE__{domain: pattern}, hostname) when is_binary(hostname) do
    matches_domain_pattern?(pattern, hostname)
  end

  @doc """
  Checks if a hostname matches a domain pattern.
  """
  def matches_domain_pattern?(pattern, hostname)
      when is_binary(pattern) and is_binary(hostname) do
    pattern = String.downcase(pattern)
    hostname = String.downcase(hostname)

    cond do
      # Exact match
      pattern == hostname ->
        true

      # Wildcard pattern: *.example.com matches sub.example.com but not example.com
      String.starts_with?(pattern, "*.") ->
        suffix = String.replace_prefix(pattern, "*", "")
        String.ends_with?(hostname, suffix) && hostname != String.replace_prefix(suffix, ".", "")

      true ->
        false
    end
  end

  @doc """
  Returns a human-readable summary of active policies.
  """
  def policy_summary(%__MODULE__{} = instance) do
    @policy_fields
    |> Enum.filter(fn field -> Map.get(instance, field, false) end)
    |> Enum.map(&policy_label/1)
  end

  defp policy_label(:blocked), do: "Blocked"
  defp policy_label(:silenced), do: "Silenced"
  defp policy_label(:media_removal), do: "Media Removed"
  defp policy_label(:media_nsfw), do: "Media NSFW"
  defp policy_label(:federated_timeline_removal), do: "FTL Removed"
  defp policy_label(:followers_only), do: "Followers Only"
  defp policy_label(:report_removal), do: "Reports Rejected"
  defp policy_label(:avatar_removal), do: "Avatars Stripped"
  defp policy_label(:banner_removal), do: "Banners Stripped"
  defp policy_label(:reject_deletes), do: "Deletes Rejected"

  @doc """
  Checks if any policy is active for this instance.
  """
  def has_any_policy?(%__MODULE__{} = instance) do
    Enum.any?(@policy_fields, fn field -> Map.get(instance, field, false) end)
  end

  @doc """
  Returns the severity level based on active policies.
  """
  def severity_level(%__MODULE__{} = instance) do
    cond do
      instance.blocked -> :blocked
      instance.silenced || instance.followers_only -> :restricted
      instance.federated_timeline_removal -> :limited
      has_any_policy?(instance) -> :modified
      true -> :none
    end
  end

  # Reachability tracking functions

  @doc """
  Checks if an instance is currently considered reachable.
  An instance is unreachable if unreachable_since is set and within the timeout period.
  """
  def reachable?(%__MODULE__{unreachable_since: nil}), do: true

  def reachable?(%__MODULE__{unreachable_since: unreachable_since}) do
    timeout_days = Application.get_env(:elektrine, :federation_reachability_timeout_days, 7)
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_days * 24 * 60 * 60, :second)
    DateTime.compare(unreachable_since, cutoff) == :gt
  end

  @doc """
  Creates a changeset to mark an instance as unreachable.
  """
  def set_unreachable_changeset(instance) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    failure_count = (instance.failure_count || 0) + 1

    instance
    |> change(%{
      unreachable_since: instance.unreachable_since || now,
      failure_count: failure_count
    })
  end

  @doc """
  Creates a changeset to mark an instance as reachable (clears unreachable status).
  """
  def set_reachable_changeset(instance) do
    instance
    |> change(%{
      unreachable_since: nil,
      failure_count: 0
    })
  end

  @doc """
  Returns the backoff duration in seconds based on failure count.
  Uses exponential backoff: 1min, 2min, 4min, 8min, ... up to 1 day max.
  """
  def backoff_duration(%__MODULE__{failure_count: count}) when is_integer(count) and count > 0 do
    # 1 minute
    base = 60
    # 1 day
    max = 86_400
    min((base * :math.pow(2, count - 1)) |> round(), max)
  end

  def backoff_duration(_), do: 0

  # NodeInfo / Metadata functions

  @doc """
  Creates a changeset for updating instance metadata (nodeinfo, favicon).
  """
  def metadata_changeset(instance, attrs) do
    instance
    |> cast(attrs, [:nodeinfo, :favicon, :metadata_updated_at])
  end

  @doc """
  Checks if the instance metadata needs to be refreshed.
  Returns true if never fetched or older than 24 hours.
  """
  def needs_metadata_update?(%__MODULE__{metadata_updated_at: nil}), do: true

  def needs_metadata_update?(%__MODULE__{metadata_updated_at: updated_at}) do
    # Refresh if older than 24 hours
    cutoff = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)
    DateTime.compare(updated_at, cutoff) == :lt
  end

  def needs_metadata_update?(nil), do: true

  @doc """
  Returns the software name from nodeinfo, if available.
  """
  def software_name(%__MODULE__{nodeinfo: %{"software" => %{"name" => name}}})
      when is_binary(name) do
    String.downcase(name)
  end

  def software_name(_), do: nil

  @doc """
  Returns the software version from nodeinfo, if available.
  """
  def software_version(%__MODULE__{nodeinfo: %{"software" => %{"version" => version}}})
      when is_binary(version) do
    version
  end

  def software_version(_), do: nil

  @doc """
  Returns user statistics from nodeinfo, if available.
  """
  def user_stats(%__MODULE__{nodeinfo: %{"usage" => %{"users" => users}}}) when is_map(users) do
    %{
      total: users["total"],
      active_month: users["activeMonth"],
      active_half_year: users["activeHalfyear"]
    }
  end

  def user_stats(_), do: nil

  @doc """
  Returns local post count from nodeinfo, if available.
  """
  def local_posts(%__MODULE__{nodeinfo: %{"usage" => %{"localPosts" => count}}})
      when is_integer(count) do
    count
  end

  def local_posts(_), do: nil

  @doc """
  Checks if the instance has open registrations.
  """
  def open_registrations?(%__MODULE__{nodeinfo: %{"openRegistrations" => open}})
      when is_boolean(open) do
    open
  end

  def open_registrations?(_), do: nil
end
