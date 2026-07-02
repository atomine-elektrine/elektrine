defmodule Elektrine.AccountsFixtures do
  @moduledoc false

  alias Elektrine.Accounts

  def unique_user_username do
    "u" <> (Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 19))
  end

  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_user_username(),
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    })
  end

  def user_fixture(attrs \\ %{}) do
    {post_registration_attrs, registration_attrs} =
      Map.split(attrs, [
        :profile_visibility,
        :allow_group_adds_from,
        :allow_direct_messages_from,
        :allow_mentions_from,
        :birthday,
        :show_birthday,
        :hide_followers,
        :hide_follows,
        :hide_favorites,
        :also_known_as,
        :moved_to,
        :notify_on_new_follower,
        :notify_on_direct_message,
        :notify_on_mention,
        :block_notifications_from_strangers,
        :hide_notification_contents
      ])

    {:ok, user} =
      registration_attrs
      |> valid_user_attributes()
      |> Accounts.create_user()

    if map_size(post_registration_attrs) > 0 do
      {:ok, updated_user} = Accounts.update_user(user, post_registration_attrs)
      updated_user
    else
      user
    end
  end
end
