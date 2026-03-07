defmodule ElektrineWeb.Plugs.HTTPSignaturePlugTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.SigningKey
  alias Elektrine.Repo
  alias ElektrineWeb.Plugs.HTTPSignaturePlug

  describe "call/2" do
    test "verifies hs2019 signatures that include created and expires params", %{conn: conn} do
      {public_key, private_key} = SigningKey.generate_key_pair()
      actor_uri = "https://8.8.8.8/users/alice"

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
      headers = ["(request-target)", "host", "date", "(created)", "(expires)"]

      signing_string =
        [
          "(request-target): post /inbox",
          "host: #{conn.host}",
          "date: #{date}",
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
        |> put_req_header("date", date)
        |> put_req_header("signature", signature_header)

      conn = HTTPSignaturePlug.call(conn, [])

      assert conn.assigns.valid_signature == true
      assert conn.assigns.signature_actor.id == actor.id
    end
  end

  defp rsa_sign(data, private_key_pem) do
    [entry] = :public_key.pem_decode(private_key_pem)
    private_key = :public_key.pem_entry_decode(entry)
    :public_key.sign(data, :sha256, private_key) |> Base.encode64()
  end
end
