defmodule Elektrine.ActivityPub.RelaySubscription do
  @moduledoc """
  Represents a subscription to a remote ActivityPub relay.

  Relays are special actors that rebroadcast public content from instances
  that follow them. By subscribing to a relay, an instance can receive
  content from other instances that also subscribe to that relay.

  ## Status Values

  - `pending` - Follow sent, awaiting Accept from relay
  - `active` - Relay accepted our follow, receiving content
  - `rejected` - Relay rejected our follow request
  - `error` - Subscription failed due to an error
  """
  use Ecto.Schema
  import Ecto.Changeset

  @status_values ~w(pending active rejected error)

  schema "activitypub_relay_subscriptions" do
    field :relay_uri, :string
    field :follow_activity_id, :string
    field :status, :string, default: "pending"
    field :relay_inbox, :string
    field :relay_name, :string
    field :relay_software, :string
    field :accepted, :boolean, default: false
    field :error_message, :string

    belongs_to :subscribed_by, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :relay_uri,
      :follow_activity_id,
      :status,
      :relay_inbox,
      :relay_name,
      :relay_software,
      :accepted,
      :error_message,
      :subscribed_by_id
    ])
    |> validate_required([:relay_uri])
    |> validate_inclusion(:status, @status_values)
    |> validate_relay_uri()
    |> unique_constraint(:relay_uri)
  end

  defp validate_relay_uri(changeset) do
    validate_change(changeset, :relay_uri, fn :relay_uri, uri ->
      case URI.parse(uri) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          []

        _ ->
          [relay_uri: "must be a valid HTTP(S) URL"]
      end
    end)
  end

  @doc """
  Returns a human-readable status label.
  """
  def status_label(%__MODULE__{status: "pending"}), do: "Pending"
  def status_label(%__MODULE__{status: "active"}), do: "Active"
  def status_label(%__MODULE__{status: "rejected"}), do: "Rejected"
  def status_label(%__MODULE__{status: "error"}), do: "Error"
  def status_label(_), do: "Unknown"

  @doc """
  Checks if the subscription is currently active.
  """
  def active?(%__MODULE__{status: "active", accepted: true}), do: true
  def active?(_), do: false
end
