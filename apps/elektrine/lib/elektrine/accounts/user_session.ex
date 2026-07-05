defmodule Elektrine.Accounts.UserSession do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_sessions" do
    belongs_to :user, Elektrine.Accounts.User

    field :auth_method, :string, default: "password"
    field :device_label, :string
    field :browser, :string
    field :platform, :string
    field :ip_address, :string
    field :user_agent, :string
    field :remembered, :boolean, default: false
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :revoked_reason, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :auth_method,
      :device_label,
      :browser,
      :platform,
      :ip_address,
      :user_agent,
      :remembered,
      :last_seen_at,
      :revoked_at,
      :revoked_reason
    ])
    |> put_default_last_seen()
    |> normalize_device_metadata()
    |> validate_required([:user_id, :auth_method, :last_seen_at])
    |> validate_length(:auth_method, max: 40)
    |> validate_length(:device_label, max: 120)
    |> validate_length(:browser, max: 80)
    |> validate_length(:platform, max: 80)
    |> validate_length(:ip_address, max: 120)
    |> validate_length(:revoked_reason, max: 120)
    |> foreign_key_constraint(:user_id)
  end

  def revoke_changeset(session, reason \\ "revoked") do
    session
    |> cast(%{revoked_at: now(), revoked_reason: reason}, [:revoked_at, :revoked_reason])
    |> validate_required([:revoked_at])
    |> validate_length(:revoked_reason, max: 120)
  end

  defp put_default_last_seen(changeset) do
    case get_field(changeset, :last_seen_at) do
      nil -> put_change(changeset, :last_seen_at, now())
      _value -> changeset
    end
  end

  defp normalize_device_metadata(changeset) do
    user_agent = get_field(changeset, :user_agent)
    browser = get_field(changeset, :browser) || browser_from_user_agent(user_agent)
    platform = get_field(changeset, :platform) || platform_from_user_agent(user_agent)
    label = get_field(changeset, :device_label) || device_label(browser, platform)

    changeset
    |> put_change(:browser, browser)
    |> put_change(:platform, platform)
    |> put_change(:device_label, label)
  end

  defp browser_from_user_agent(user_agent) when is_binary(user_agent) do
    cond do
      String.contains?(user_agent, "Edg/") -> "Edge"
      String.contains?(user_agent, "Firefox/") -> "Firefox"
      String.contains?(user_agent, "Chrome/") -> "Chrome"
      String.contains?(user_agent, "Safari/") -> "Safari"
      true -> "Browser"
    end
  end

  defp browser_from_user_agent(_), do: "Browser"

  defp platform_from_user_agent(user_agent) when is_binary(user_agent) do
    cond do
      String.contains?(user_agent, "Windows") -> "Windows"
      String.contains?(user_agent, "Mac OS X") -> "macOS"
      String.contains?(user_agent, "Android") -> "Android"
      String.contains?(user_agent, "iPhone") or String.contains?(user_agent, "iPad") -> "iOS"
      String.contains?(user_agent, "Linux") -> "Linux"
      true -> "Unknown device"
    end
  end

  defp platform_from_user_agent(_), do: "Unknown device"

  defp device_label(browser, platform) do
    [browser, platform]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" on ")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
