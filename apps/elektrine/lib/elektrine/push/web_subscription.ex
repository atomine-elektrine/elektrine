defmodule Elektrine.Push.WebSubscription do
  @moduledoc """
  Browser Web Push subscription for API clients.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Elektrine.Secrets.EncryptedString
  alias Elektrine.Security.URLValidator

  @policies ["all", "followed", "follower", "none"]

  schema "web_push_subscriptions" do
    field :endpoint, EncryptedString
    field :endpoint_hash, :string
    field :p256dh, EncryptedString
    field :auth, EncryptedString
    field :alerts, :map, default: %{}
    field :policy, :string, default: "all"
    field :enabled, :boolean, default: true
    field :last_used_at, :utc_datetime
    field :failed_count, :integer, default: 0
    field :last_error, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :endpoint,
      :endpoint_hash,
      :p256dh,
      :auth,
      :alerts,
      :policy,
      :enabled,
      :last_used_at,
      :failed_count,
      :last_error,
      :user_id
    ])
    |> validate_required([:endpoint, :endpoint_hash, :p256dh, :auth, :user_id])
    |> validate_endpoint()
    |> validate_length(:endpoint_hash, is: 64)
    |> validate_inclusion(:policy, @policies)
    |> validate_alerts()
    |> unique_constraint(:endpoint_hash)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_endpoint(changeset) do
    validate_change(changeset, :endpoint, fn :endpoint, endpoint ->
      case URI.parse(endpoint) do
        %URI{scheme: "https", host: host} when is_binary(host) ->
          if (Mix.env() == :test and String.ends_with?(host, ".example")) or
               URLValidator.validate(endpoint) == :ok,
             do: [],
             else: [endpoint: "is not a safe public URL"]

        _ ->
          [endpoint: "must be an HTTPS public URL"]
      end
    end)
  end

  def update_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:alerts, :policy, :enabled, :last_used_at, :failed_count, :last_error])
    |> validate_inclusion(:policy, @policies)
    |> validate_alerts()
  end

  defp validate_alerts(changeset) do
    validate_change(changeset, :alerts, fn :alerts, alerts ->
      if is_map(alerts) and Enum.all?(alerts, fn {_key, value} -> is_boolean(value) end) do
        []
      else
        [alerts: "must be a map of boolean alert flags"]
      end
    end)
  end
end
