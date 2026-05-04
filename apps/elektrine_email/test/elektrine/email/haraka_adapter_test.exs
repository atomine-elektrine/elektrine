defmodule Elektrine.Email.HarakaAdapterTest do
  use ExUnit.Case, async: false

  import Swoosh.Email

  alias Elektrine.Email.HarakaAdapter
  alias Elektrine.Email.InternalOrigin

  setup do
    previous_secret = System.get_env("HARAKA_INTERNAL_SIGNING_SECRET")
    System.put_env("HARAKA_INTERNAL_SIGNING_SECRET", "adapter-test-secret")

    on_exit(fn -> restore_env("HARAKA_INTERNAL_SIGNING_SECRET", previous_secret) end)
  end

  test "build_api_body signs Swoosh mail with internal origin headers" do
    body =
      new()
      |> from({"Elektrine Support", "support@example.com"})
      |> to("support@example.com")
      |> subject("Reset your Elektrine password")
      |> text_body("Reset instructions")
      |> HarakaAdapter.build_api_body()
      |> Jason.decode!()

    headers = body["headers"]

    assert body["from"] == "Elektrine Support <support@example.com>"
    assert headers["X-Elektrine-Origin"] == "internal"
    assert headers["X-Elektrine-Origin-Ts"]
    assert headers["X-Elektrine-Origin-Sig"]
    assert InternalOrigin.valid?(headers, body["from"])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
