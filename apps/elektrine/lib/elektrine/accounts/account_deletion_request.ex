defmodule Elektrine.Accounts.AccountDeletionRequest do
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Accounts.User

  schema "account_deletion_requests" do
    field :reason, :string
    field :status, :string, default: "pending"
    field :requested_at, :utc_datetime
    field :reviewed_at, :utc_datetime
    field :admin_notes, :string

    belongs_to :user, User
    belongs_to :reviewed_by, User

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending approved denied)

  @doc """
  Changeset for creating a new account deletion request.
  """
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :reason, :requested_at])
    |> validate_required([:user_id, :requested_at])
    |> validate_length(:reason, max: 1000)
    |> put_change(:status, "pending")
    |> unique_constraint(:user_id, message: "You already have a pending deletion request")
  end

  @doc """
  Changeset for admin review of deletion request.
  """
  def review_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :reviewed_at, :reviewed_by_id, :admin_notes])
    |> validate_required([:status, :reviewed_at, :reviewed_by_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:admin_notes, max: 1000)
  end

  @doc """
  Returns true if the request is pending review.
  """
  def pending?(%__MODULE__{status: "pending"}), do: true
  def pending?(_), do: false

  @doc """
  Returns true if the request has been approved.
  """
  def approved?(%__MODULE__{status: "approved"}), do: true
  def approved?(_), do: false

  @doc """
  Returns true if the request has been denied.
  """
  def denied?(%__MODULE__{status: "denied"}), do: true
  def denied?(_), do: false
end
