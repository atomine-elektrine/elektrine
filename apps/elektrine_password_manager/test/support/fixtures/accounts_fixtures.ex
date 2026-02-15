defmodule Elektrine.AccountsFixtures do
  @moduledoc false

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
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.create_user()

    user
  end
end
