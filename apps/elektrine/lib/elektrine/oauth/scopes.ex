defmodule Elektrine.OAuth.Scopes do
  @moduledoc """
  OAuth scope definitions and validation for the Mastodon API.

  Scopes control what actions an OAuth token is allowed to perform.
  This follows the Mastodon API scope hierarchy.
  """

  # All valid OAuth scopes
  @valid_scopes [
    # Read scopes
    "read",
    "read:accounts",
    "read:blocks",
    "read:bookmarks",
    "read:favourites",
    "read:filters",
    "read:follows",
    "read:lists",
    "read:mutes",
    "read:notifications",
    "read:search",
    "read:statuses",
    # Write scopes
    "write",
    "write:accounts",
    "write:blocks",
    "write:bookmarks",
    "write:conversations",
    "write:favourites",
    "write:filters",
    "write:follows",
    "write:lists",
    "write:media",
    "write:mutes",
    "write:notifications",
    "write:reports",
    "write:statuses",
    # Follow scope (special for follow/unfollow actions)
    "follow",
    # Push notifications
    "push",
    # Admin scopes
    "admin:read",
    "admin:read:accounts",
    "admin:read:reports",
    "admin:read:domain_allows",
    "admin:read:domain_blocks",
    "admin:read:ip_blocks",
    "admin:read:email_domain_blocks",
    "admin:read:canonical_email_blocks",
    "admin:write",
    "admin:write:accounts",
    "admin:write:reports",
    "admin:write:domain_allows",
    "admin:write:domain_blocks",
    "admin:write:ip_blocks",
    "admin:write:email_domain_blocks",
    "admin:write:canonical_email_blocks"
  ]

  @doc """
  Returns all valid OAuth scopes.
  """
  @spec valid_scopes() :: [String.t()]
  def valid_scopes, do: @valid_scopes

  @doc """
  Checks if a scope is valid.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(scope), do: scope in @valid_scopes

  @doc """
  Filters a list of scopes to only include valid ones.
  """
  @spec filter_valid([String.t()]) :: [String.t()]
  def filter_valid(scopes) when is_list(scopes) do
    Enum.filter(scopes, &valid?/1)
  end

  @doc """
  Fetches scopes from params, with a default fallback.
  Handles both string and list formats.
  """
  @spec fetch_scopes(map(), [String.t()]) :: [String.t()]
  def fetch_scopes(params, default \\ ["read"])

  def fetch_scopes(%{scope: scope}, default) when is_binary(scope) do
    parse_scopes(scope, default)
  end

  def fetch_scopes(%{scopes: scopes}, default) when is_list(scopes) do
    case filter_valid(scopes) do
      [] -> default
      valid -> valid
    end
  end

  def fetch_scopes(%{"scope" => scope}, default) when is_binary(scope) do
    parse_scopes(scope, default)
  end

  def fetch_scopes(%{"scopes" => scopes}, default) when is_list(scopes) do
    case filter_valid(scopes) do
      [] -> default
      valid -> valid
    end
  end

  def fetch_scopes(_, default), do: default

  @doc """
  Parses a space-separated scope string.
  """
  @spec parse_scopes(String.t(), [String.t()]) :: [String.t()]
  def parse_scopes(scope_string, default \\ ["read"]) when is_binary(scope_string) do
    scopes =
      scope_string
      |> String.split(~r/[\s,]+/, trim: true)
      |> filter_valid()

    case scopes do
      [] -> default
      valid -> valid
    end
  end

  @doc """
  Checks if one scope contains another (scope hierarchy).

  For example, "read" contains "read:accounts".
  """
  @spec contains?(String.t(), String.t()) :: boolean()
  def contains?(container, contained) when container == contained, do: true

  def contains?(container, contained) do
    case String.split(contained, ":") do
      [base | _rest] when base == container -> true
      _ -> false
    end
  end

  @doc """
  Checks if a list of scopes satisfies a required scope.
  """
  @spec satisfied?([String.t()], String.t()) :: boolean()
  def satisfied?(scopes, required) when is_list(scopes) do
    Enum.any?(scopes, fn scope -> contains?(scope, required) end)
  end

  @doc """
  Checks if a list of scopes satisfies all required scopes.
  """
  @spec all_satisfied?([String.t()], [String.t()]) :: boolean()
  def all_satisfied?(scopes, required_scopes) do
    Enum.all?(required_scopes, fn required -> satisfied?(scopes, required) end)
  end

  @doc """
  Converts a list of scopes to a space-separated string.
  """
  @spec to_string([String.t()]) :: String.t()
  def to_string(scopes) when is_list(scopes) do
    Enum.join(scopes, " ")
  end
end
