defmodule Elektrine.Email.ExternalDeliveryControl do
  @moduledoc """
  Admin controls for pausing outbound delivery by user or recipient domain.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Repo

  @scope_types ~w(user domain)

  schema "external_email_delivery_controls" do
    field :scope_type, :string
    field :scope_value, :string
    field :active, :boolean, default: true
    field :reason, :string
    field :paused_at, :utc_datetime
    field :resumed_at, :utc_datetime
    field :paused_by_id, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(control, attrs) do
    control
    |> cast(attrs, [
      :scope_type,
      :scope_value,
      :active,
      :reason,
      :paused_by_id,
      :paused_at,
      :resumed_at
    ])
    |> update_change(:scope_type, &normalize_scope_type/1)
    |> update_change(:scope_value, &normalize_scope_value/1)
    |> validate_required([:scope_type, :scope_value, :active])
    |> validate_inclusion(:scope_type, @scope_types)
    |> unique_constraint([:scope_type, :scope_value],
      name: :external_email_delivery_controls_scope_unique
    )
  end

  def pause(scope_type, scope_value, attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      scope_type: scope_type,
      scope_value: scope_value,
      active: true,
      reason: Keyword.get(attrs, :reason),
      paused_by_id: Keyword.get(attrs, :paused_by_id),
      paused_at: now,
      resumed_at: nil
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          active: true,
          reason: attrs.reason,
          paused_by_id: attrs.paused_by_id,
          paused_at: attrs.paused_at,
          resumed_at: nil,
          updated_at: now
        ]
      ],
      conflict_target: [:scope_type, :scope_value],
      returning: true
    )
  end

  def resume(scope_type, scope_value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get(scope_type, scope_value) do
      %__MODULE__{} = control ->
        control
        |> changeset(%{active: false, resumed_at: now})
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  def get(scope_type, scope_value) do
    scope_type = normalize_scope_type(scope_type)
    scope_value = normalize_scope_value(scope_value)

    Repo.one(
      from c in __MODULE__,
        where: c.scope_type == ^scope_type and c.scope_value == ^scope_value
    )
  end

  def active_controls do
    Repo.all(from c in __MODULE__, where: c.active == true, order_by: [desc: c.updated_at])
  end

  def paused?(user_id, domain) do
    user_scope = normalize_scope_value(user_id)
    domain_scope = normalize_scope_value(domain)

    Repo.exists?(
      from c in __MODULE__,
        where: c.active == true,
        where:
          (c.scope_type == "user" and c.scope_value == ^user_scope) or
            (c.scope_type == "domain" and c.scope_value == ^domain_scope)
    )
  end

  defp normalize_scope_type(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp normalize_scope_value(nil), do: ""

  defp normalize_scope_value(value),
    do: value |> to_string() |> String.trim() |> String.downcase()
end
