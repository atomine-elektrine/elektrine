defmodule ElektrineWeb.ChangesetJSON do
  @doc """
  Renders changeset errors.
  """
  def error(%{changeset: changeset}) do
    # When encoded, the changeset returns its errors
    # as a JSON object. So we just pass it forward.
    %{
      errors:
        Ecto.Changeset.traverse_errors(changeset, &ElektrineWeb.CoreComponents.translate_error/1)
    }
  end
end
