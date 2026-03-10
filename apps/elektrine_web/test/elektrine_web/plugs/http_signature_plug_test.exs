defmodule ElektrineWeb.Plugs.HTTPSignaturePlugTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.SigningKey
  alias Elektrine.Repo
  alias ElektrineWeb.Plugs.HTTPSignaturePlug

  describe "call/2" do
    test "verifies hs2019 signatures that include created, expires, and digest", %{conn: conn} do
      {public_key, private_key} = SigningKey.generate_key_pair()
      actor_uri = "https://8.8.8.8/users/alice"
      body = Jason.encode!(%{"type" => "Follow", "actor" => actor_uri})

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "alice",
          domain: "8.8.8.8",
          inbox_url: "https://8.8.8.8/inbox",
          public_key: public_key,
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{}
        })
        |> Repo.insert!()

      %SigningKey{}
      |> SigningKey.remote_changeset(%{
        key_id: "#{actor_uri}#main-key",
        remote_actor_id: actor.id,
        public_key: public_key
      })
      |> Repo.insert!()

      created = Integer.to_string(System.system_time(:second))
      expires = Integer.to_string(System.system_time(:second) + 300)
      date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
      digest = digest(body)
      headers = ["(request-target)", "host", "date", "digest", "(created)", "(expires)"]

      signing_string =
        [
          "(request-target): post /inbox",
          "host: #{conn.host}",
          "date: #{date}",
          "digest: #{digest}",
          "(created): #{created}",
          "(expires): #{expires}"
        ]
        |> Enum.join("\n")

      signature_header =
        [
          ~s(keyId="#{actor_uri}#main-key"),
          ~s(algorithm="hs2019"),
          "created=#{created}",
          "expires=#{expires}",
          ~s(headers="#{Enum.join(headers, " ")}"),
          ~s(signature="#{rsa_sign(signing_string, private_key)}")
        ]
        |> Enum.join(",")

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/inbox")
        |> Map.put(:query_string, "")
        |> Plug.Conn.assign(:raw_body, body)
        |> put_req_header("date", date)
        |> put_req_header("digest", digest)
        |> put_req_header("signature", signature_header)

      conn = HTTPSignaturePlug.call(conn, [])

      assert conn.assigns.valid_signature == true
      assert conn.assigns.signature_actor.id == actor.id
    end

    test "rejects signatures whose digest does not match the raw body", %{conn: conn} do
      {public_key, private_key} = SigningKey.generate_key_pair()
      actor_uri = "https://8.8.8.8/users/alice"
      signed_body = Jason.encode!(%{"type" => "Follow", "actor" => actor_uri})
      actual_body = Jason.encode!(%{"type" => "Follow", "actor" => actor_uri, "extra" => true})

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "alice",
          domain: "8.8.8.8",
          inbox_url: "https://8.8.8.8/inbox",
          public_key: public_key,
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{}
        })
        |> Repo.insert!()

      %SigningKey{}
      |> SigningKey.remote_changeset(%{
        key_id: "#{actor_uri}#main-key",
        remote_actor_id: actor.id,
        public_key: public_key
      })
      |> Repo.insert!()

      created = Integer.to_string(System.system_time(:second))
      expires = Integer.to_string(System.system_time(:second) + 300)
      date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
      digest = digest(signed_body)

      signing_string =
        [
          "(request-target): post /inbox",
          "host: #{conn.host}",
          "date: #{date}",
          "digest: #{digest}",
          "(created): #{created}",
          "(expires): #{expires}"
        ]
        |> Enum.join("\n")

      signature_header =
        [
          ~s(keyId="#{actor_uri}#main-key"),
          ~s(algorithm="hs2019"),
          "created=#{created}",
          "expires=#{expires}",
          ~s|headers="(request-target) host date digest (created) (expires)"|,
          ~s(signature="#{rsa_sign(signing_string, private_key)}")
        ]
        |> Enum.join(",")

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/inbox")
        |> Map.put(:query_string, "")
        |> Plug.Conn.assign(:raw_body, actual_body)
        |> put_req_header("date", date)
        |> put_req_header("digest", digest)
        |> put_req_header("signature", signature_header)

      conn = HTTPSignaturePlug.call(conn, [])

      assert conn.assigns.valid_signature == false
      assert conn.assigns.signature_error == :digest_mismatch
    end

    test "rejects stale signatures", %{conn: conn} do
      {public_key, private_key} = SigningKey.generate_key_pair()
      actor_uri = "https://8.8.8.8/users/alice"
      body = Jason.encode!(%{"type" => "Follow", "actor" => actor_uri})

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "alice",
          domain: "8.8.8.8",
          inbox_url: "https://8.8.8.8/inbox",
          public_key: public_key,
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{}
        })
        |> Repo.insert!()

      %SigningKey{}
      |> SigningKey.remote_changeset(%{
        key_id: "#{actor_uri}#main-key",
        remote_actor_id: actor.id,
        public_key: public_key
      })
      |> Repo.insert!()

      created = Integer.to_string(System.system_time(:second) - 3_600)
      expires = Integer.to_string(System.system_time(:second) - 3_300)
      date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
      digest = digest(body)

      signing_string =
        [
          "(request-target): post /inbox",
          "host: #{conn.host}",
          "date: #{date}",
          "digest: #{digest}",
          "(created): #{created}",
          "(expires): #{expires}"
        ]
        |> Enum.join("\n")

      signature_header =
        [
          ~s(keyId="#{actor_uri}#main-key"),
          ~s(algorithm="hs2019"),
          "created=#{created}",
          "expires=#{expires}",
          ~s|headers="(request-target) host date digest (created) (expires)"|,
          ~s(signature="#{rsa_sign(signing_string, private_key)}")
        ]
        |> Enum.join(",")

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/inbox")
        |> Map.put(:query_string, "")
        |> Plug.Conn.assign(:raw_body, body)
        |> put_req_header("date", date)
        |> put_req_header("digest", digest)
        |> put_req_header("signature", signature_header)

      conn = HTTPSignaturePlug.call(conn, [])

      assert conn.assigns.valid_signature == false
      assert conn.assigns.signature_error == :stale_signature
    end
  end

  defp rsa_sign(data, private_key_pem) do
    [entry] = :public_key.pem_decode(private_key_pem)
    private_key = :public_key.pem_entry_decode(entry)
    :public_key.sign(data, :sha256, private_key) |> Base.encode64()
  end

  defp digest(body) do
    "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
  end
end
