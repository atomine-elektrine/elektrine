defmodule Elektrine.AccountIdentifiers do
  @moduledoc """
  Shared helpers for rendering local account handles and public contact addresses.
  """

  alias Elektrine.Domains

  def local_handle(%{} = user) do
    user
    |> Map.get(:handle)
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> Map.get(user, :username)
          trimmed -> trimmed
        end

      _ ->
        Map.get(user, :username)
    end
    |> local_handle()
  end

  def local_handle(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      identifier -> identifier <> "@" <> Domains.default_user_handle_domain()
    end
  end

  def local_handle(_), do: nil

  def at_local_handle(user_or_value) do
    case local_handle(user_or_value) do
      value when is_binary(value) -> "@" <> value
      _ -> nil
    end
  end

  def public_contact_email(%{} = user) do
    case Map.get(user, :username) do
      username when is_binary(username) and username != "" ->
        String.trim(username) <> "@" <> Domains.default_user_handle_domain()

      _ ->
        nil
    end
  end

  def public_contact_email(_), do: nil

  def public_contact_mailto(user) do
    case public_contact_email(user) do
      email when is_binary(email) -> "mailto:" <> email
      _ -> nil
    end
  end
end
