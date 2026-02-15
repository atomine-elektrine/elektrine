defmodule Elektrine.Email.SafeSender do
  @moduledoc """
  Schema for safe/whitelisted email senders.
  Emails from safe senders bypass spam filtering.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_safe_senders" do
    field :email, :string
    field :domain, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Creates a changeset for adding a safe sender.
  Either email or domain must be provided, but not both.
  """
  def changeset(safe_sender, attrs) do
    safe_sender
    |> cast(attrs, [:email, :domain, :user_id])
    |> validate_required([:user_id])
    |> validate_email_or_domain()
    |> normalize_email()
    |> normalize_domain()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :email])
    |> unique_constraint([:user_id, :domain])
  end

  defp validate_email_or_domain(changeset) do
    email = get_field(changeset, :email)
    domain = get_field(changeset, :domain)

    cond do
      is_nil(email) && is_nil(domain) ->
        add_error(changeset, :email, "either email or domain must be provided")

      !is_nil(email) && !is_nil(domain) ->
        add_error(changeset, :email, "cannot add both email and domain in same entry")

      !is_nil(email) ->
        validate_format(changeset, :email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
          message: "must be a valid email format"
        )

      !is_nil(domain) ->
        validate_format(changeset, :domain, ~r/^[a-zA-Z0-9][a-zA-Z0-9\-\.]*\.[a-zA-Z]{2,}$/,
          message: "must be a valid domain format"
        )
    end
  end

  defp normalize_email(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :email, String.downcase(String.trim(email)))
    end
  end

  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      nil -> changeset
      domain -> put_change(changeset, :domain, String.downcase(String.trim(domain)))
    end
  end
end
