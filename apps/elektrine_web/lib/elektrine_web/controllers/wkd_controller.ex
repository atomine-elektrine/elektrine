defmodule ElektrineWeb.WKDController do
  @moduledoc "Web Key Directory (WKD) controller for serving PGP public keys.\n\nImplements the direct method as per draft-koch-openpgp-webkey-service.\nClients can discover PGP keys by requesting:\n  /.well-known/openpgpkey/hu/{z-base32-sha1-hash-of-local-part}\n\nThe hash is computed as: z-base32(sha1(lowercase(local-part)))\n"
  use ElektrineWeb, :controller
  alias Elektrine.Accounts.User
  alias Elektrine.Email.PGP
  alias Elektrine.Repo
  import Ecto.Query
  require Logger

  @doc "Serves a PGP public key for a user based on the WKD hash.\nReturns the key as application/octet-stream (binary format).\n"
  def get_key(conn, %{"hash" => hash}) do
    case find_user_by_wkd_hash(hash) do
      {:ok, user} ->
        if user.pgp_public_key do
          case dearmor_key(user.pgp_public_key) do
            {:ok, binary_key} ->
              conn
              |> put_resp_content_type("application/octet-stream")
              |> send_resp(200, binary_key)

            {:error, _} ->
              conn
              |> put_resp_content_type("application/octet-stream")
              |> send_resp(200, user.pgp_public_key)
          end
        else
          conn |> put_resp_content_type("text/plain") |> send_resp(404, "No key found")
        end

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "No key found")
    end
  end

  @doc "Serves the WKD policy file.\nAn empty policy means the server follows default WKD behavior.\n"
  def policy(conn, _params) do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, "")
  end

  defp find_user_by_wkd_hash(hash) do
    case Repo.one(
           from(u in User, where: u.pgp_wkd_hash == ^hash and not is_nil(u.pgp_public_key))
         ) do
      %User{} = user -> {:ok, user}
      nil -> find_user_by_wkd_hash_fallback(hash)
    end
  end

  defp find_user_by_wkd_hash_fallback(hash) do
    candidates =
      Repo.all(
        from(u in User,
          where: is_nil(u.pgp_wkd_hash) and not is_nil(u.pgp_public_key),
          select: {u.id, u.username}
        )
      )

    case Enum.find_value(candidates, fn {id, username} ->
           if PGP.wkd_hash(username) == hash do
             id
           else
             nil
           end
         end) do
      nil ->
        {:error, :not_found}

      user_id ->
        _ =
          Repo.update_all(from(u in User, where: u.id == ^user_id and is_nil(u.pgp_wkd_hash)),
            set: [pgp_wkd_hash: hash]
          )

        {:ok, Repo.get!(User, user_id)}
    end
  end

  defp dearmor_key(armored_key) do
    lines = String.split(armored_key, ~r/\r?\n/)

    content =
      lines
      |> Enum.drop_while(&(!String.starts_with?(&1, "-----BEGIN")))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.starts_with?(&1, "-----END")))
      |> Enum.reject(&(&1 == "" || String.starts_with?(&1, "=") || String.contains?(&1, ":")))
      |> Enum.join("")

    case Base.decode64(content) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  rescue
    _ -> {:error, :parse_error}
  end
end
