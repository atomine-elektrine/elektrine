defmodule Elektrine.Strings do
  @moduledoc false

  def present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def present(_), do: nil

  def present?(value) do
    not is_nil(present(value))
  end
end
