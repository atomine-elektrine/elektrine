defmodule Elektrine.Email.CategoryPreference do
  @moduledoc """
  Learned category preferences for incoming senders and domains.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_category_preferences" do
    field :email, :string
    field :domain, :string
    field :category, :string
    field :confidence, :float, default: 0.7
    field :learned_count, :integer, default: 1
    field :source, :string, default: "manual_move"
    field :last_learned_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @valid_categories ~w(feed ledger)

  @doc """
  Creates a changeset for a learned category preference.
  """
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [
      :email,
      :domain,
      :category,
      :confidence,
      :learned_count,
      :source,
      :last_learned_at,
      :user_id
    ])
    |> validate_required([:category, :user_id])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:learned_count, greater_than_or_equal_to: 1)
    |> validate_email_or_domain()
    |> normalize_email()
    |> normalize_domain()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :email], name: :email_category_preferences_user_email_idx)
    |> unique_constraint([:user_id, :domain], name: :email_category_preferences_user_domain_idx)
  end

  defp validate_email_or_domain(changeset) do
    email = get_field(changeset, :email)
    domain = get_field(changeset, :domain)

    cond do
      is_nil(email) && is_nil(domain) ->
        add_error(changeset, :email, "either email or domain must be provided")

      !is_nil(email) && !is_nil(domain) ->
        add_error(changeset, :email, "cannot set both email and domain in same entry")

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
