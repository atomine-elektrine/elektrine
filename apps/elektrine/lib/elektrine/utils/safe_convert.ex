defmodule Elektrine.Utils.SafeConvert do
  @moduledoc """
  Provides safe conversion functions that handle invalid user input gracefully.

  These functions prevent crashes from invalid `String.to_integer()` calls by
  returning default values or error tuples instead of raising ArgumentError.
  """

  @doc """
  Safely converts a string to an integer, returning a default value on failure.

  ## Examples

      iex> SafeConvert.to_integer("123")
      123

      iex> SafeConvert.to_integer("invalid")
      nil

      iex> SafeConvert.to_integer("invalid", 0)
      0

      iex> SafeConvert.to_integer(123)
      123
  """
  def to_integer(value, default \\ nil)

  def to_integer(value, _default) when is_integer(value), do: value

  def to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  def to_integer(_value, default), do: default

  @doc """
  Safely converts a string to an integer, always returning a value (never nil or raises).

  This is useful when you need to ensure you always get either the converted integer
  or a specific default value.

  ## Examples

      iex> SafeConvert.to_integer!("123", 1)
      123

      iex> SafeConvert.to_integer!("invalid", 1)
      1

      iex> SafeConvert.to_integer!(nil, 1)
      1
  """
  def to_integer!(value, default) do
    to_integer(value, default)
  end

  @doc """
  Parses a page number from params, with safe defaults.

  ## Examples

      iex> SafeConvert.parse_page(%{"page" => "2"})
      2

      iex> SafeConvert.parse_page(%{"page" => "invalid"})
      1

      iex> SafeConvert.parse_page(%{})
      1

      iex> SafeConvert.parse_page(%{"p" => "3"}, "p")
      3
  """
  def parse_page(params, key \\ "page", default \\ 1) do
    params
    |> Map.get(key, "#{default}")
    |> to_integer(default)
    # Ensure page is at least 1
    |> max(1)
  end

  @doc """
  Parses an ID string and returns a result tuple.

  ## Examples

      iex> SafeConvert.parse_id("123")
      {:ok, 123}

      iex> SafeConvert.parse_id("invalid")
      {:error, :invalid_id}

      iex> SafeConvert.parse_id(123)
      {:ok, 123}
  """
  def parse_id(value) when is_integer(value), do: {:ok, value}

  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  def parse_id(_value), do: {:error, :invalid_id}

  @doc """
  Parses multiple IDs from a list of strings.

  ## Examples

      iex> SafeConvert.parse_ids(["1", "2", "3"])
      {:ok, [1, 2, 3]}

      iex> SafeConvert.parse_ids(["1", "invalid", "3"])
      {:error, :invalid_id}
  """
  def parse_ids(values) when is_list(values) do
    results = Enum.map(values, &parse_id/1)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(results, fn {:ok, id} -> id end)}
    else
      {:error, :invalid_id}
    end
  end

  @doc """
  Parses a limit parameter with validation and max cap.

  ## Examples

      iex> SafeConvert.parse_limit("50", 100)
      50

      iex> SafeConvert.parse_limit("200", 100)
      100

      iex> SafeConvert.parse_limit("invalid", 100)
      100
  """
  def parse_limit(value, max_limit) when is_binary(value) do
    value
    |> to_integer(max_limit)
    |> min(max_limit)
    |> max(1)
  end

  def parse_limit(_value, max_limit), do: max_limit

  @doc """
  Parses a timeout value in seconds with validation.

  ## Examples

      iex> SafeConvert.parse_timeout("30")
      30

      iex> SafeConvert.parse_timeout("invalid")
      30

      iex> SafeConvert.parse_timeout("5", min: 10)
      10
  """
  def parse_timeout(value, opts \\ []) do
    default = Keyword.get(opts, :default, 30)
    min_timeout = Keyword.get(opts, :min, 1)
    max_timeout = Keyword.get(opts, :max, 300)

    value
    |> to_integer(default)
    |> max(min_timeout)
    |> min(max_timeout)
  end
end
