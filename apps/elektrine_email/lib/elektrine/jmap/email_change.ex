defmodule Elektrine.JMAP.EmailChange do
  @moduledoc """
  Tracks email mutations against monotonically increasing JMAP Email state counters.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Multi
  alias Elektrine.JMAP.State
  alias Elektrine.Repo

  @change_types ~w(created updated destroyed)

  schema "jmap_email_changes" do
    field :email_id, :integer
    field :change_type, :string
    field :state_counter, :integer

    belongs_to :mailbox, Elektrine.Email.Mailbox

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [:mailbox_id, :email_id, :change_type, :state_counter])
    |> validate_required([:mailbox_id, :email_id, :change_type, :state_counter])
    |> validate_inclusion(:change_type, @change_types)
  end

  @doc """
  Records an email change and bumps the Email state counter atomically.
  """
  def record(mailbox_id, email_id, change_type, extra_entity_types \\ [])
      when is_integer(mailbox_id) and is_integer(email_id) and change_type in @change_types do
    extra_entity_types =
      extra_entity_types
      |> List.wrap()
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "Email"))

    result =
      Multi.new()
      |> Multi.run(:state_counter, fn _repo, _changes ->
        {:ok, State.increment_state(mailbox_id, "Email") |> String.to_integer()}
      end)
      |> Multi.insert(:change, fn %{state_counter: state_counter} ->
        changeset(%__MODULE__{}, %{
          mailbox_id: mailbox_id,
          email_id: email_id,
          change_type: change_type,
          state_counter: state_counter
        })
      end)
      |> add_extra_state_increments(mailbox_id, extra_entity_types)
      |> Repo.transaction()

    case result do
      {:ok, %{change: change}} -> {:ok, change}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Lists email changes after a state counter, ordered oldest-first.
  """
  def list_since(mailbox_id, since_counter, current_counter)
      when is_integer(mailbox_id) and is_integer(since_counter) and is_integer(current_counter) do
    Repo.all(
      from c in __MODULE__,
        where:
          c.mailbox_id == ^mailbox_id and c.state_counter > ^since_counter and
            c.state_counter <= ^current_counter,
        order_by: [asc: c.state_counter, asc: c.id]
    )
  end

  defp add_extra_state_increments(multi, mailbox_id, entity_types) do
    Enum.reduce(entity_types, multi, fn entity_type, acc ->
      Multi.run(acc, {:state, entity_type}, fn _repo, _changes ->
        {:ok, State.increment_state(mailbox_id, entity_type)}
      end)
    end)
  end
end
