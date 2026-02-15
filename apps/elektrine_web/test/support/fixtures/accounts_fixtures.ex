defmodule Elektrine.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Elektrine.Accounts` context.
  """

  alias Elektrine.Accounts

  def unique_user_username, do: "user#{System.unique_integer([:positive])}"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_user_username(),
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    })
  end

  def user_fixture(attrs \\ %{}) do
    # Separate registration attrs from other attrs
    {privacy_attrs, registration_attrs} =
      Map.split(attrs, [
        :profile_visibility,
        :allow_group_adds_from,
        :allow_direct_messages_from,
        :allow_mentions_from,
        :notify_on_new_follower,
        :notify_on_direct_message,
        :notify_on_mention
      ])

    {:ok, user} =
      registration_attrs
      |> valid_user_attributes()
      |> Accounts.create_user()

    # If there are privacy settings, update the user with them
    if map_size(privacy_attrs) > 0 do
      {:ok, updated_user} = Accounts.update_user(user, privacy_attrs)
      updated_user
    else
      user
    end
  end
end
