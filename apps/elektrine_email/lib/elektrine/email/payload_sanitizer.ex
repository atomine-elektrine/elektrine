defmodule Elektrine.Email.PayloadSanitizer do
  @moduledoc false

  @postgres_null_byte <<0>>

  def strip_postgres_null_bytes(value) when is_binary(value) do
    :binary.replace(value, @postgres_null_byte, "", [:global])
  end

  def strip_postgres_null_bytes(value) when is_list(value) do
    Enum.map(value, &strip_postgres_null_bytes/1)
  end

  def strip_postgres_null_bytes(%_{} = value), do: value

  def strip_postgres_null_bytes(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {strip_key_null_bytes(key), strip_postgres_null_bytes(item)}
    end)
  end

  def strip_postgres_null_bytes(value), do: value

  defp strip_key_null_bytes(key) when is_binary(key), do: strip_postgres_null_bytes(key)
  defp strip_key_null_bytes(key), do: key
end
