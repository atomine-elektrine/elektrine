defmodule Elektrine.ActivityPub.ActorURLSecurityTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.Actor

  describe "changeset URL security" do
    test "rejects unsafe required actor URLs" do
      for {field, value} <- [
            {:uri, "javascript:alert(1)"},
            {:uri, "https://user:pass@example.com/users/alice"},
            {:inbox_url, "//evil.example/inbox"},
            {:inbox_url, "https://example.com/inbox\r\nx-injected: yes"}
          ] do
        attrs =
          valid_attrs()
          |> Map.put(field, value)

        changeset = Actor.changeset(%Actor{}, attrs)

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field)
      end
    end

    test "rejects unsafe optional actor URLs" do
      changeset =
        Actor.changeset(
          %Actor{},
          valid_attrs(%{
            avatar_url: "javascript:alert(1)",
            header_url: "https://user:pass@example.com/header.png",
            outbox_url: "//evil.example/outbox"
          })
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :avatar_url)
      assert Keyword.has_key?(changeset.errors, :header_url)
      assert Keyword.has_key?(changeset.errors, :outbox_url)
    end

    test "accepts safe actor URLs" do
      changeset =
        Actor.changeset(
          %Actor{},
          valid_attrs(%{
            avatar_url: "https://example.com/avatar.png",
            header_url: "https://example.com/header.png",
            outbox_url: "https://example.com/users/alice/outbox",
            followers_url: "https://example.com/users/alice/followers",
            following_url: "https://example.com/users/alice/following",
            moderators_url: "https://example.com/c/community/moderators"
          })
        )

      assert changeset.valid?
    end
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        uri: "https://example.com/users/alice",
        username: "alice",
        domain: "example.com",
        inbox_url: "https://example.com/users/alice/inbox"
      },
      overrides
    )
  end
end
