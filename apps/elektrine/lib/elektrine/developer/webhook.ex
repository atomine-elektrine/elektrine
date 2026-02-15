defmodule Elektrine.Developer.Webhook do
  @moduledoc """
  Schema for developer webhooks.

  Stores outbound webhook subscriptions configured by users and delivery metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_events ~w(
    email.received
    email.sent
    message.received
    post.created
    post.liked
    follow.new
    export.completed
  )
  @allow_http_localhost Mix.env() in [:dev, :test]

  schema "developer_webhooks" do
    field :name, :string
    field :url, :string
    field :events, {:array, :string}, default: []
    field :secret, :string
    field :enabled, :boolean, default: true
    field :last_triggered_at, :utc_datetime
    field :last_response_status, :integer
    field :last_error, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Returns valid webhook event names.
  """
  def valid_events, do: @valid_events

  @doc """
  Changeset for creating/updating webhooks.
  """
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :url, :events, :enabled, :user_id, :secret])
    |> validate_required([:name, :url, :events, :user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:events, min: 1, max: 20)
    |> validate_event_names()
    |> validate_webhook_url()
    |> maybe_generate_secret()
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for recording webhook delivery results.
  """
  def delivery_result_changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:last_triggered_at, :last_response_status, :last_error])
  end

  defp validate_event_names(changeset) do
    events = get_field(changeset, :events, [])
    invalid_events = Enum.filter(events, &(&1 not in @valid_events))

    if invalid_events == [] do
      changeset
    else
      add_error(changeset, :events, "contains invalid events: #{Enum.join(invalid_events, ", ")}")
    end
  end

  defp validate_webhook_url(changeset) do
    validate_change(changeset, :url, fn :url, value ->
      with %URI{scheme: scheme, host: host} = uri <- URI.parse(value),
           true <- is_binary(host) and host != "",
           true <- webhook_scheme_allowed?(scheme, host),
           true <- is_nil(uri.userinfo) do
        []
      else
        _ ->
          [url: "must be a valid HTTPS URL"]
      end
    end)
  end

  defp webhook_scheme_allowed?("https", _host), do: true

  defp webhook_scheme_allowed?("http", host) do
    @allow_http_localhost and host in ["localhost", "127.0.0.1", "::1"]
  end

  defp webhook_scheme_allowed?(_, _), do: false

  defp maybe_generate_secret(changeset) do
    case get_field(changeset, :secret) do
      secret when is_binary(secret) and secret != "" ->
        changeset

      _ ->
        put_change(
          changeset,
          :secret,
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        )
    end
  end
end
