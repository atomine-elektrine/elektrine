defmodule ElektrineWeb.JMAP.SessionController do
  @moduledoc """
  JMAP Session controller for the discovery endpoint.
  Returns capabilities, account information, and endpoint URLs.
  """
  use ElektrineEmailWeb, :controller

  alias Elektrine.Email
  alias Elektrine.JMAP
  import Plug.Conn, only: [get_req_header: 2]

  @doc """
  GET /.well-known/jmap
  Returns the JMAP session object with capabilities and account info.
  """
  def session(conn, _params) do
    user = conn.assigns[:current_user]
    account_id = conn.assigns[:jmap_account_id]
    mailbox = Email.get_user_mailbox(user.id)

    host = get_host(conn)

    session = %{
      "capabilities" => capabilities(),
      "accounts" => %{
        account_id => account_capabilities(user, mailbox)
      },
      "primaryAccounts" => %{
        "urn:ietf:params:jmap:mail" => account_id,
        "urn:ietf:params:jmap:submission" => account_id
      },
      "username" => user.username,
      "apiUrl" => "#{host}/jmap/",
      "downloadUrl" => "#{host}/jmap/download/{accountId}/{blobId}/{name}?type={type}",
      "uploadUrl" => "#{host}/jmap/upload/{accountId}",
      "eventSourceUrl" =>
        "#{host}/jmap/eventsource?types={types}&closeafter={closeafter}&ping={ping}",
      "state" => JMAP.get_session_state(mailbox.id)
    }

    json(conn, session)
  end

  defp capabilities do
    %{
      "urn:ietf:params:jmap:core" => %{
        "maxSizeUpload" => 52_428_800,
        "maxConcurrentUpload" => 4,
        "maxSizeRequest" => 10_485_760,
        "maxConcurrentRequests" => 4,
        "maxCallsInRequest" => 16,
        "maxObjectsInGet" => 500,
        "maxObjectsInSet" => 500,
        "collationAlgorithms" => ["i;ascii-casemap", "i;octet"]
      },
      "urn:ietf:params:jmap:mail" => %{
        "maxMailboxesPerEmail" => 10,
        "maxMailboxDepth" => 10,
        "maxSizeMailboxName" => 256,
        "maxSizeAttachmentsPerEmail" => 52_428_800,
        "emailQuerySortOptions" => ["receivedAt", "sentAt", "subject", "from", "size"],
        "mayCreateTopLevelMailbox" => false
      },
      "urn:ietf:params:jmap:submission" => %{
        "maxDelayedSend" => 44_236_800,
        "submissionExtensions" => %{}
      }
    }
  end

  defp account_capabilities(user, mailbox) do
    %{
      "name" => mailbox.email || "#{user.username}@elektrine.com",
      "isPersonal" => true,
      "isReadOnly" => false,
      "accountCapabilities" => %{
        "urn:ietf:params:jmap:core" => %{},
        "urn:ietf:params:jmap:mail" => %{},
        "urn:ietf:params:jmap:submission" => %{}
      }
    }
  end

  defp get_host(conn) do
    scheme =
      cond do
        conn.scheme == :https -> "https"
        forwarded_as_https?(conn) -> "https"
        true -> "http"
      end

    host = conn.host
    port = conn.port

    if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp forwarded_as_https?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [value | _] ->
        value
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> String.downcase() == "https"

      _ ->
        false
    end
  end
end
