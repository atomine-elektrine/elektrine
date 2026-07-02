defmodule Elektrine.Accounts.AccountNote do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  schema "account_notes" do
    field :comment, :string

    belongs_to :source_user, Elektrine.Accounts.User
    belongs_to :target_user, Elektrine.Accounts.User
    belongs_to :target_remote_actor, Elektrine.ActivityPub.Actor

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:source_user_id, :target_user_id, :target_remote_actor_id, :comment])
    |> update_change(:comment, &normalize_comment/1)
    |> validate_required([:source_user_id])
    |> validate_target()
    |> validate_length(:comment, max: 5_000)
    |> unique_constraint([:source_user_id, :target_user_id])
    |> unique_constraint([:source_user_id, :target_remote_actor_id])
    |> check_constraint(:target_user_id, name: :account_notes_exactly_one_target)
    |> foreign_key_constraint(:source_user_id)
    |> foreign_key_constraint(:target_user_id)
    |> foreign_key_constraint(:target_remote_actor_id)
  end

  defp validate_target(changeset) do
    target_user_id = get_field(changeset, :target_user_id)
    target_remote_actor_id = get_field(changeset, :target_remote_actor_id)

    case {is_nil(target_user_id), is_nil(target_remote_actor_id)} do
      {false, true} -> changeset
      {true, false} -> changeset
      _ -> add_error(changeset, :base, "must have exactly one target")
    end
  end

  defp normalize_comment(value) when is_binary(value), do: String.trim(value)
  defp normalize_comment(value), do: value
end
