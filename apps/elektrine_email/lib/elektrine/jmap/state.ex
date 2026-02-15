defmodule Elektrine.JMAP.State do
  @moduledoc """
  State tracking for JMAP delta synchronization.
  Tracks state counters per entity type per mailbox for efficient sync.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Repo

  @entity_types ~w(Mailbox Email Thread EmailSubmission)

  schema "jmap_state_tracking" do
    field :entity_type, :string
    field :state_counter, :integer, default: 0

    belongs_to :mailbox, Elektrine.Email.Mailbox

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for state tracking.
  """
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:mailbox_id, :entity_type, :state_counter])
    |> validate_required([:mailbox_id, :entity_type])
    |> validate_inclusion(:entity_type, @entity_types)
    |> unique_constraint([:mailbox_id, :entity_type])
  end

  @doc """
  Gets the current state string for an entity type.
  Returns "0" if no state exists yet.
  """
  def get_state(mailbox_id, entity_type) do
    case Repo.one(
           from s in __MODULE__,
             where: s.mailbox_id == ^mailbox_id and s.entity_type == ^entity_type,
             select: s.state_counter
         ) do
      nil -> "0"
      counter -> to_string(counter)
    end
  end

  @doc """
  Increments the state counter for an entity type and returns the new state string.
  Uses upsert to handle concurrent updates safely.
  """
  def increment_state(mailbox_id, entity_type) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.insert!(
        %__MODULE__{mailbox_id: mailbox_id, entity_type: entity_type, state_counter: 1},
        on_conflict: [
          inc: [state_counter: 1],
          set: [updated_at: now]
        ],
        conflict_target: [:mailbox_id, :entity_type],
        returning: true
      )

    to_string(result.state_counter)
  end

  @doc """
  Checks if a state is valid (exists and matches or is newer).
  Returns {:ok, current_state} if valid, {:error, :invalid_state} if not.
  """
  def validate_state(mailbox_id, entity_type, since_state) do
    current = get_state(mailbox_id, entity_type)
    current_int = String.to_integer(current)
    since_int = String.to_integer(since_state)

    if since_int <= current_int do
      {:ok, current}
    else
      {:error, :invalid_state}
    end
  end

  @doc """
  Gets the state counter as an integer for comparison.
  """
  def get_state_counter(mailbox_id, entity_type) do
    mailbox_id
    |> get_state(entity_type)
    |> String.to_integer()
  end

  @doc """
  Initializes state tracking for a new mailbox.
  Creates entries for all entity types.
  """
  def initialize_for_mailbox(mailbox_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(@entity_types, fn entity_type ->
        %{
          mailbox_id: mailbox_id,
          entity_type: entity_type,
          state_counter: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(__MODULE__, entries, on_conflict: :nothing)
  end
end
