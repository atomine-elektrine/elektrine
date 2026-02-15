defmodule ElektrineWeb.MastodonAPI.ErrorView do
  @moduledoc """
  Error view for Mastodon API responses.
  """

  use ElektrineWeb, :html

  def render("error.json", %{error: error}) do
    %{error: error}
  end

  def render("changeset_error.json", %{changeset: changeset}) do
    errors = format_changeset_errors(changeset)

    %{
      error: "Validation failed",
      error_description: errors |> Map.values() |> List.flatten() |> Enum.join(", ")
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
