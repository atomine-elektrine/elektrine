defmodule ElektrineEmailWeb.EmailLive.Settings.Helpers do
  @moduledoc """
  Helpers shared across the email settings domain modules.
  """

  alias ElektrineEmailWeb.UserErrorHelpers

  def get_changeset_error(changeset) do
    UserErrorHelpers.join_changeset_errors(changeset,
      fallback: "Please review the form and try again."
    )
  end

  def parse_positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse_positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  def parse_positive_id(_value), do: :error
end
