defmodule Elektrine.Time do
  @moduledoc false

  def utc_now do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  def truncate(nil), do: nil
  def truncate(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)
  def truncate(value), do: value
end
