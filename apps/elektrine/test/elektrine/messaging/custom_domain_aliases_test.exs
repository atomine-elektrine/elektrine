defmodule Elektrine.Messaging.CustomDomainAliasesTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatConversation
  alias Elektrine.Messaging.ChatConversationMember
  alias Elektrine.Messaging.Federation.Builders
  alias Elektrine.Messaging.Federation.DirectMessageState
  alias Elektrine.Messaging.Federation.Utils
  alias Elektrine.Profiles
  alias Elektrine.Repo

  test "build_dm_message_created_event uses the sender's verified custom domain" do
    sender = user_fixture(%{username: "dmcustomsender"})
    custom_domain = verified_profile_custom_domain_fixture(sender, "dmcustomsender.test")

    conversation =
      %ChatConversation{}
      |> ChatConversation.dm_changeset(%{
        creator_id: sender.id,
        name: "@alice@remote.example",
        federated_source: "arblarg:dm:handle:alice@remote.example"
      })
      |> Repo.insert!()

    conversation.id
    |> ChatConversationMember.add_member_changeset(sender.id)
    |> Repo.insert!()

    assert {:ok, message} =
             Messaging.create_chat_text_message(conversation.id, sender.id, "hello custom domain")

    assert {:ok, event} =
             Builders.build_dm_message_created_event(
               message,
               "alice@remote.example",
               builder_context()
             )

    assert event["origin_domain"] == custom_domain.domain

    assert event["stream_id"] ==
             "dm:https://#{custom_domain.domain}/_arblarg/dms/#{conversation.id}"

    assert get_in(event, ["payload", "dm", "id"]) ==
             "https://#{custom_domain.domain}/_arblarg/dms/#{conversation.id}"

    assert get_in(event, ["payload", "message", "id"]) ==
             "https://#{custom_domain.domain}/_arblarg/messages/#{message.id}"

    assert get_in(event, ["payload", "dm", "sender", "handle"]) ==
             "#{sender.username}@#{custom_domain.domain}"

    assert get_in(event, ["payload", "dm", "sender", "uri"]) ==
             "https://#{custom_domain.domain}/users/#{sender.username}"
  end

  test "create_remote_dm_conversation treats a verified custom profile domain as local" do
    sender = user_fixture(%{username: "localdmsender"})
    recipient = user_fixture(%{username: "localdmrecipient"})
    custom_domain = verified_profile_custom_domain_fixture(recipient, "localdmalias.test")

    assert {:ok, conversation} =
             Messaging.create_remote_dm_conversation(
               sender.id,
               "#{recipient.username}@#{custom_domain.domain}"
             )

    member_ids =
      from(cm in ChatConversationMember,
        where: cm.conversation_id == ^conversation.id and is_nil(cm.left_at),
        select: cm.user_id
      )
      |> Repo.all()
      |> Enum.sort()

    assert conversation.type == "dm"
    assert member_ids == Enum.sort([sender.id, recipient.id])
  end

  test "resolve_local_dm_recipient accepts verified custom profile domains" do
    user = user_fixture(%{username: "inboundcustomdm"})
    custom_domain = verified_profile_custom_domain_fixture(user, "inboundcustomdm.test")

    payload = %{
      "id" => "https://#{custom_domain.domain}/users/#{user.username}",
      "uri" => "https://#{custom_domain.domain}/users/#{user.username}",
      "username" => user.username,
      "domain" => custom_domain.domain,
      "handle" => "#{user.username}@#{custom_domain.domain}"
    }

    assert {:ok, resolved_user} =
             DirectMessageState.resolve_local_dm_recipient(payload, %{
               local_domain: &Elektrine.Messaging.Federation.Runtime.local_domain/0
             })

    assert resolved_user.id == user.id
    assert Utils.preferred_dm_origin_domain_for_user(user) == custom_domain.domain
  end

  defp builder_context do
    %{
      local_domain: &Elektrine.Messaging.Federation.Runtime.local_domain/0,
      local_event_signing_material:
        &Elektrine.Messaging.Federation.Runtime.local_event_signing_material/0,
      outgoing_peers: fn -> [] end,
      maybe_iso8601: fn
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
        nil -> nil
        _ -> nil
      end,
      normalize_optional_string: fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end,
      presence_ttl_seconds: fn -> 60 end
    }
  end

  defp verified_profile_custom_domain_fixture(user, domain) do
    {:ok, custom_domain} = Profiles.create_custom_domain(user, %{"domain" => domain})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(cd in Elektrine.Profiles.CustomDomain, where: cd.id == ^custom_domain.id)
    |> Repo.update_all(set: [status: "verified", verified_at: now, last_checked_at: now])

    Profiles.get_verified_custom_domain(domain)
  end
end
