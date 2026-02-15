defmodule ElektrineWeb.DAV.AddressBookControllerTest do
  use ElektrineWeb.ConnCase

  alias Elektrine.Accounts
  alias Elektrine.Email.Contacts

  @test_password "testpassword123"

  # Helper to create a test user
  defp create_test_user(attrs \\ %{}) do
    default_attrs = %{
      username: "carduser#{System.unique_integer([:positive])}",
      password: @test_password,
      password_confirmation: @test_password
    }

    {:ok, user} = Accounts.create_user(Map.merge(default_attrs, attrs))
    user
  end

  # Helper to create an authenticated connection using Basic auth
  defp auth_conn(conn, user) do
    encoded = Base.encode64("#{user.username}:#{@test_password}")

    conn
    |> put_req_header("authorization", "Basic #{encoded}")
  end

  describe "propfind_home/2" do
    test "returns addressbook home properties", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "0")
        |> put_req_header("content-type", "application/xml")
        |> request(:propfind, "/addressbooks/#{user.username}/")

      assert conn.status == 207
      assert response_content_type(conn, :xml)
      body = conn.resp_body

      assert body =~ "multistatus"
      assert body =~ "/addressbooks/#{user.username}/"
    end

    test "returns forbidden for wrong user", %{conn: conn} do
      user = create_test_user()
      other_user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> request(:propfind, "/addressbooks/#{other_user.username}/")

      assert conn.status == 403
    end

    test "includes contacts addressbook at depth 1", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "1")
        |> request(:propfind, "/addressbooks/#{user.username}/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ "/addressbooks/#{user.username}/contacts/"
    end
  end

  describe "propfind_addressbook/2" do
    test "returns addressbook properties", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "0")
        |> request(:propfind, "/addressbooks/#{user.username}/contacts/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ "multistatus"
      assert body =~ "addressbook"
    end

    test "includes contacts at depth 1", %{conn: conn} do
      user = create_test_user()

      # Create a contact
      {:ok, contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "test-contact-uid",
          name: "Test Contact",
          email: "test@example.com"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "1")
        |> request(:propfind, "/addressbooks/#{user.username}/contacts/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ contact.uid
    end
  end

  describe "get_contact/2" do
    test "returns contact as vCard", %{conn: conn} do
      user = create_test_user()

      {:ok, contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "test-get-uid",
          name: "Get Test",
          formatted_name: "Get Test",
          email: "get@example.com"
        })

      conn =
        conn
        |> auth_conn(user)
        |> get("/addressbooks/#{user.username}/contacts/#{contact.uid}.vcf")

      assert conn.status == 200
      # Content-type should be text/vcard
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/vcard"
      body = conn.resp_body

      assert body =~ "BEGIN:VCARD"
      assert body =~ "Get Test"
    end

    test "returns 404 for non-existent contact", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> get("/addressbooks/#{user.username}/contacts/nonexistent.vcf")

      assert conn.status == 404
    end

    test "returns forbidden for wrong user", %{conn: conn} do
      user = create_test_user()
      other_user = create_test_user()

      {:ok, contact} =
        Contacts.create_contact_carddav(%{
          user_id: other_user.id,
          uid: "other-contact",
          name: "Other Contact",
          email: "other@example.com"
        })

      conn =
        conn
        |> auth_conn(user)
        |> get("/addressbooks/#{other_user.username}/contacts/#{contact.uid}.vcf")

      assert conn.status == 403
    end
  end

  describe "put_contact/2" do
    @valid_vcard """
    BEGIN:VCARD
    VERSION:3.0
    UID:new-contact-uid
    FN:New Contact
    N:Contact;New;;;
    EMAIL:new@example.com
    END:VCARD
    """

    test "creates a new contact", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/vcard")
        |> put("/addressbooks/#{user.username}/contacts/new-contact-uid.vcf", @valid_vcard)

      assert conn.status == 201
      assert get_resp_header(conn, "etag") != []

      # Verify contact was created
      contact = Contacts.get_contact_by_uid(user.id, "new-contact-uid")
      assert contact != nil
      assert contact.formatted_name == "New Contact"
    end

    test "updates an existing contact", %{conn: conn} do
      user = create_test_user()

      {:ok, contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "update-contact",
          name: "Original Name",
          email: "original@example.com"
        })

      updated_vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:update-contact
      FN:Updated Name
      EMAIL:updated@example.com
      END:VCARD
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/vcard")
        |> put_req_header("if-match", "\"#{contact.etag}\"")
        |> put("/addressbooks/#{user.username}/contacts/update-contact.vcf", updated_vcard)

      assert conn.status == 204

      # Verify contact was updated
      updated = Contacts.get_contact_by_uid(user.id, "update-contact")
      assert updated.formatted_name == "Updated Name"
    end

    test "returns 412 when If-None-Match * and contact exists", %{conn: conn} do
      user = create_test_user()

      {:ok, _contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "existing-contact",
          name: "Existing",
          email: "existing@example.com"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/vcard")
        |> put_req_header("if-none-match", "*")
        |> put("/addressbooks/#{user.username}/contacts/existing-contact.vcf", @valid_vcard)

      assert conn.status == 412
    end

    test "returns 412 when If-Match with wrong etag", %{conn: conn} do
      user = create_test_user()

      {:ok, _contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "etag-mismatch",
          name: "Etag Test",
          email: "etag@example.com"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/vcard")
        |> put_req_header("if-match", "\"wrong-etag\"")
        |> put("/addressbooks/#{user.username}/contacts/etag-mismatch.vcf", @valid_vcard)

      assert conn.status == 412
    end

    test "returns 400 for invalid vCard", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/vcard")
        |> put("/addressbooks/#{user.username}/contacts/invalid.vcf", "not a valid vcard")

      assert conn.status == 400
    end
  end

  describe "delete_contact/2" do
    test "deletes a contact", %{conn: conn} do
      user = create_test_user()

      {:ok, contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "delete-me",
          name: "Delete Me",
          email: "delete@example.com"
        })

      conn =
        conn
        |> auth_conn(user)
        |> delete("/addressbooks/#{user.username}/contacts/#{contact.uid}.vcf")

      assert conn.status == 204

      # Verify contact was deleted
      assert Contacts.get_contact_by_uid(user.id, "delete-me") == nil
    end

    test "returns 404 for non-existent contact", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> delete("/addressbooks/#{user.username}/contacts/nonexistent.vcf")

      assert conn.status == 404
    end
  end

  describe "report/2" do
    test "handles addressbook-multiget", %{conn: conn} do
      user = create_test_user()

      {:ok, contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "multiget-contact",
          name: "Multiget Test",
          email: "multiget@example.com"
        })

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <C:addressbook-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
        <D:prop>
          <D:getetag/>
          <C:address-data/>
        </D:prop>
        <D:href>/addressbooks/#{user.username}/contacts/#{contact.uid}.vcf</D:href>
      </C:addressbook-multiget>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:report, "/addressbooks/#{user.username}/contacts/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "Multiget Test"
    end

    test "handles addressbook-query", %{conn: conn} do
      user = create_test_user()

      {:ok, _contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "query-contact",
          name: "Query Test",
          email: "query@example.com"
        })

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
        <D:prop>
          <D:getetag/>
          <C:address-data/>
        </D:prop>
      </C:addressbook-query>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:report, "/addressbooks/#{user.username}/contacts/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "Query Test"
    end

    test "handles sync-collection", %{conn: conn} do
      user = create_test_user()

      {:ok, _contact} =
        Contacts.create_contact_carddav(%{
          user_id: user.id,
          uid: "sync-contact",
          name: "Sync Test",
          email: "sync@example.com"
        })

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:sync-collection xmlns:D="DAV:">
        <D:sync-token/>
        <D:prop>
          <D:getetag/>
        </D:prop>
      </D:sync-collection>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:report, "/addressbooks/#{user.username}/contacts/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "sync-contact"
    end
  end

  # Helper to make custom HTTP method requests
  defp request(conn, method, path, body \\ nil) do
    # Ensure content-type is set for methods with body
    conn =
      if method in [:propfind, :report] and !body do
        conn
        |> put_req_header("content-type", "application/xml")
      else
        conn
      end

    body = body || ""

    conn
    |> Phoenix.ConnTest.dispatch(ElektrineWeb.Endpoint, method, path, body)
  end
end
