defmodule Elektrine.JMAP.EmailTombstone do
  @moduledoc """
  Tracks deleted email ids so JMAP Email/changes can surface destroys.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Repo

  schema "jmap_email_tombstones" do
    field :email_id, :integer

    belongs_to :mailbox, Elektrine.Email.Mailbox

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [:mailbox_id, :email_id])
    |> validate_required([:mailbox_id, :email_id])
  end

  @doc """
  Records a deleted email id for later JMAP sync.
  """
  def create(mailbox_id, email_id) when is_integer(mailbox_id) and is_integer(email_id) do
    %__MODULE__{}
    |> changeset(%{mailbox_id: mailbox_id, email_id: email_id})
    |> Repo.insert()
  end

  @doc """
  Returns deleted email ids recorded at or after the provided cutoff.
  """
  def list_since(mailbox_id, %DateTime{} = cutoff) do
    Repo.all(
      from t in __MODULE__,
        where: t.mailbox_id == ^mailbox_id and t.inserted_at >= ^cutoff,
        order_by: [asc: t.inserted_at, asc: t.id],
        select: t.email_id
    )
  end

  @doc """
  Returns the latest tombstone timestamp for a mailbox.
  """
  def latest_timestamp(mailbox_id) do
    Repo.one(
      from t in __MODULE__,
        where: t.mailbox_id == ^mailbox_id,
        select: max(t.inserted_at)
    )
  end
end
