defmodule Elektrine.Developer.Webhook do
  @moduledoc """
  Schema for developer webhooks.

  Stores outbound webhook subscriptions configured by users and delivery metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Elektrine.Security.URLValidator

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

  @doc """
  Validates that a webhook URL is safe for outbound delivery.
  """
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)
    host = normalize_host(uri.host)

    cond do
      uri.scheme in [nil, ""] ->
        {:error, :missing_scheme}

      not is_binary(host) or host == "" ->
        {:error, :missing_host}

      not is_nil(uri.userinfo) ->
        {:error, :userinfo_not_allowed}

      uri.scheme == "http" and localhost_http_allowed?(host) ->
        :ok

      uri.scheme != "https" ->
        {:error, :https_required}

      true ->
        URLValidator.validate(url)
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

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
      case validate_url(value) do
        :ok -> []
        {:error, reason} -> [url: webhook_url_error(reason)]
      end
    end)
  end

  defp webhook_url_error(:https_required), do: "must be a valid HTTPS URL"
  defp webhook_url_error(:userinfo_not_allowed), do: "must not include username or password"

  defp webhook_url_error(:private_ip),
    do: "must not point to private or internal addresses"

  defp webhook_url_error(:private_domain),
    do: "must not point to private or internal domains"

  defp webhook_url_error(:unresolvable_host), do: "must use a resolvable public hostname"
  defp webhook_url_error(_), do: "must be a valid public HTTPS URL"

  defp localhost_http_allowed?(host) do
    @allow_http_localhost and host in ["localhost", "127.0.0.1", "::1"]
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.downcase()
  end

  defp normalize_host(_), do: nil

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
