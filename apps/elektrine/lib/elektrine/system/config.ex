defmodule Elektrine.System.Config do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "system_config" do
    field :key, :string
    field :value, :string
    field :type, :string, default: "string"
    field :description, :string

    timestamps()
  end

  @doc false
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:key, :value, :type, :description])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
    |> validate_inclusion(:type, ["string", "boolean", "integer", "json"])
  end

  def parse_value(%__MODULE__{type: "boolean", value: value}) do
    value in ["true", "1", "yes", "on"]
  end

  def parse_value(%__MODULE__{type: "integer", value: value}) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  def parse_value(%__MODULE__{type: "json", value: value}) do
    case Jason.decode(value) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  def parse_value(%__MODULE__{value: value}), do: value
end
