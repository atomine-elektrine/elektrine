defmodule Elektrine.Input do
  @moduledoc false

  def sanitize_email(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[A-Za-z0-9.!#$%&'*+\/?=_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/u, value) do
      value
    else
      ""
    end
  end

  def sanitize_email(_), do: ""

  def sanitize_username(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^[:alnum:]_.+\- ]/u, "")
    |> String.slice(0, 128)
  end

  def sanitize_username(_), do: ""
end
