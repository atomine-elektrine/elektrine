defmodule Elektrine.Social.Filter do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(keyword domain actor community media sensitive boost reply)
  @actions ~w(hide warn)
  @contexts ~w(home notifications public thread account)

  schema "social_filters" do
    field :kind, :string
    field :value, :string
    field :contexts, {:array, :string}, default: []
    field :action, :string, default: "hide"
    field :whole_word, :boolean, default: false
    field :expires_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:user_id, :kind, :value, :contexts, :action, :whole_word, :expires_at])
    |> update_change(:kind, &normalize_string/1)
    |> update_change(:action, &normalize_string/1)
    |> update_change(:value, &trim_or_nil/1)
    |> update_change(:expires_at, &Elektrine.Time.truncate/1)
    |> normalize_contexts()
    |> validate_required([:user_id, :kind, :action])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:action, @actions)
    |> validate_value_for_kind()
    |> foreign_key_constraint(:user_id)
  end

  def kinds, do: @kinds
  def actions, do: @actions
  def contexts, do: @contexts

  defp normalize_contexts(changeset) do
    update_change(changeset, :contexts, fn contexts ->
      contexts
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> Enum.filter(&(&1 in @contexts))
      |> Enum.uniq()
    end)
  end

  defp validate_value_for_kind(changeset) do
    case get_field(changeset, :kind) do
      kind when kind in ["media", "sensitive", "boost", "reply"] ->
        changeset

      _ ->
        validate_required(changeset, [:value])
    end
  end

  defp normalize_string(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_string(value), do: value

  defp trim_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp trim_or_nil(value), do: value
end
