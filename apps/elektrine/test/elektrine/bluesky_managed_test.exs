defmodule Elektrine.BlueskyManagedTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Bluesky.Managed
  alias Elektrine.Repo

  defmodule MockHTTPClient do
    def put_responses(responses), do: Process.put(:bluesky_managed_mock_responses, responses)
    def clear_responses, do: Process.delete(:bluesky_managed_mock_responses)
    def clear_requests, do: Process.delete(:bluesky_managed_mock_requests)

    def requests do
      Process.get(:bluesky_managed_mock_requests, [])
      |> Enum.reverse()
    end

    def request(method, url, headers, body, opts) do
      request = %{method: method, url: url, headers: headers, body: body, opts: opts}

      Process.put(
        :bluesky_managed_mock_requests,
        [request | Process.get(:bluesky_managed_mock_requests, [])]
      )

      case Process.get(:bluesky_managed_mock_responses, []) do
        [next | rest] ->
          Process.put(:bluesky_managed_mock_responses, rest)
          next

        [] ->
          {:error, :no_mock_response}
      end
    end
  end

  setup do
    previous = Application.get_env(:elektrine, :bluesky, [])

    Application.put_env(:elektrine, :bluesky,
      enabled: true,
      inbound_enabled: true,
      managed_enabled: true,
      managed_service_url: "https://pds.example.com",
      managed_domain: "bsky.example.com",
      managed_admin_password: "admin-password",
      service_url: "https://pds.example.com",
      timeout_ms: 5_000,
      http_client: MockHTTPClient
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :bluesky, previous)
      MockHTTPClient.clear_requests()
      MockHTTPClient.clear_responses()
    end)

    :ok
  end

  test "enable_for_user provisions account and stores app password" do
    user = user_fixture()

    MockHTTPClient.put_responses([
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"code" => "invite-123"})}},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "did" => "did:plc:testdid",
             "handle" => "#{user.username}.bsky.example.com"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"name" => "elektrine", "password" => "app-password-1"})
       }}
    ])

    assert {:ok, %{did: "did:plc:testdid", handle: handle, user: updated_user}} =
             Managed.enable_for_user(user, valid_user_password())

    assert handle == "#{user.username}.bsky.example.com"
    assert updated_user.bluesky_enabled
    assert updated_user.bluesky_identifier == "did:plc:testdid"
    assert updated_user.bluesky_did == "did:plc:testdid"
    assert updated_user.bluesky_app_password == "app-password-1"
    assert updated_user.bluesky_pds_url == "https://pds.example.com"

    reloaded = Repo.get!(User, user.id)
    assert reloaded.bluesky_enabled
    assert reloaded.bluesky_app_password == "app-password-1"

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 4
    assert Enum.at(requests, 0).url =~ "/xrpc/com.atproto.server.createInviteCode"
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.server.createAccount"
    assert Enum.at(requests, 2).url =~ "/xrpc/com.atproto.server.createSession"
    assert Enum.at(requests, 3).url =~ "/xrpc/com.atproto.server.createAppPassword"
  end

  test "enable_for_user retries once when managed service closes the connection" do
    user = user_fixture()

    MockHTTPClient.put_responses([
      {:error, %Mint.TransportError{reason: :closed}},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"code" => "invite-123"})}},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "did" => "did:plc:testdid",
             "handle" => "#{user.username}.bsky.example.com"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"name" => "elektrine", "password" => "app-password-1"})
       }}
    ])

    assert {:ok, %{did: "did:plc:testdid", handle: handle, user: updated_user}} =
             Managed.enable_for_user(user, valid_user_password())

    assert handle == "#{user.username}.bsky.example.com"
    assert updated_user.bluesky_enabled
    assert updated_user.bluesky_app_password == "app-password-1"

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 5
    assert Enum.at(requests, 0).url =~ "/xrpc/com.atproto.server.createInviteCode"
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.server.createInviteCode"
    assert Enum.at(requests, 2).url =~ "/xrpc/com.atproto.server.createAccount"
    assert Enum.at(requests, 3).url =~ "/xrpc/com.atproto.server.createSession"
    assert Enum.at(requests, 4).url =~ "/xrpc/com.atproto.server.createAppPassword"
  end

  test "returns invalid credentials for wrong password" do
    user = user_fixture()

    assert {:error, :invalid_credentials} = Managed.enable_for_user(user, "wrong-password")
    assert MockHTTPClient.requests() == []
  end

  test "returns managed disabled when feature is off" do
    Application.put_env(:elektrine, :bluesky,
      enabled: true,
      managed_enabled: false,
      service_url: "https://pds.example.com",
      timeout_ms: 5_000,
      http_client: MockHTTPClient
    )

    user = user_fixture()
    assert {:error, :managed_pds_disabled} = Managed.enable_for_user(user, valid_user_password())
    assert MockHTTPClient.requests() == []
  end

  test "reconnect_for_user refreshes app password for an existing managed account" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        "bluesky_enabled" => true,
        "bluesky_identifier" => "did:plc:testdid",
        "bluesky_app_password" => "old-app-password",
        "bluesky_pds_url" => "https://pds.example.com"
      })

    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [bluesky_did: "did:plc:testdid"])

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "accessJwt" => "jwt-reconnect",
             "did" => "did:plc:testdid",
             "handle" => "#{user.username}.bsky.example.com"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"name" => "elektrine", "password" => "app-password-2"})
       }}
    ])

    assert {:ok, %{user: updated_user, did: "did:plc:testdid"}} =
             Managed.reconnect_for_user(user, valid_user_password())

    assert updated_user.bluesky_enabled
    assert updated_user.bluesky_identifier == "did:plc:testdid"
    assert updated_user.bluesky_did == "did:plc:testdid"
    assert updated_user.bluesky_app_password == "app-password-2"

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 2
    assert Enum.at(requests, 0).url =~ "/xrpc/com.atproto.server.createSession"
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.server.createAppPassword"
  end

  test "reconnect_for_user uses a unique app password name on each reconnect" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        "bluesky_enabled" => true,
        "bluesky_identifier" => "did:plc:testdid",
        "bluesky_app_password" => "old-app-password",
        "bluesky_pds_url" => "https://pds.example.com"
      })

    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [bluesky_did: "did:plc:testdid"])

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "accessJwt" => "jwt-reconnect-1",
             "did" => "did:plc:testdid",
             "handle" => "#{user.username}.bsky.example.com"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"name" => "elektrine", "password" => "app-password-2"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "accessJwt" => "jwt-reconnect-2",
             "did" => "did:plc:testdid",
             "handle" => "#{user.username}.bsky.example.com"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"name" => "elektrine", "password" => "app-password-3"})
       }}
    ])

    assert {:ok, _} = Managed.reconnect_for_user(user, valid_user_password())
    assert {:ok, _} = Managed.reconnect_for_user(user, valid_user_password())

    app_password_requests =
      MockHTTPClient.requests()
      |> Enum.filter(fn request ->
        String.contains?(request.url, "/xrpc/com.atproto.server.createAppPassword")
      end)

    assert Enum.count(app_password_requests) == 2

    app_password_names =
      Enum.map(app_password_requests, fn request ->
        request.body
        |> Jason.decode!()
        |> Map.fetch!("name")
      end)

    assert Enum.uniq(app_password_names) == app_password_names
    assert Enum.all?(app_password_names, &String.starts_with?(&1, "elektrine-"))
  end

  test "reconnect_for_user retries app password creation once when pds returns 500" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        "bluesky_enabled" => true,
        "bluesky_identifier" => "did:plc:testdid",
        "bluesky_app_password" => "old-app-password",
        "bluesky_pds_url" => "https://pds.example.com"
      })

    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [bluesky_did: "did:plc:testdid"])

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "accessJwt" => "jwt-reconnect",
             "did" => "did:plc:testdid",
             "handle" => "#{user.username}.bsky.example.com"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 500,
         body: Jason.encode!(%{"error" => "InternalServerError"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"name" => "elektrine", "password" => "app-password-2"})
       }}
    ])

    assert {:ok, %{user: updated_user, did: "did:plc:testdid"}} =
             Managed.reconnect_for_user(user, valid_user_password())

    assert updated_user.bluesky_enabled
    assert updated_user.bluesky_app_password == "app-password-2"

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 3
    assert Enum.at(requests, 0).url =~ "/xrpc/com.atproto.server.createSession"
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.server.createAppPassword"
    assert Enum.at(requests, 2).url =~ "/xrpc/com.atproto.server.createAppPassword"

    first_name = Enum.at(requests, 1).body |> Jason.decode!() |> Map.fetch!("name")
    second_name = Enum.at(requests, 2).body |> Jason.decode!() |> Map.fetch!("name")

    refute first_name == second_name
  end

  test "disconnect_for_user clears managed bluesky linkage fields" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        "bluesky_enabled" => true,
        "bluesky_identifier" => "did:plc:testdid",
        "bluesky_app_password" => "old-app-password",
        "bluesky_pds_url" => "https://pds.example.com"
      })

    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [bluesky_did: "did:plc:testdid", bluesky_inbound_cursor: "cursor-1"])

    assert {:ok, updated_user} = Managed.disconnect_for_user(user, valid_user_password())

    assert updated_user.bluesky_enabled == false
    assert is_nil(updated_user.bluesky_identifier)
    assert is_nil(updated_user.bluesky_app_password)
    assert is_nil(updated_user.bluesky_did)
    assert is_nil(updated_user.bluesky_pds_url)
    assert is_nil(updated_user.bluesky_inbound_cursor)
  end
end
