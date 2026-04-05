defmodule ElektrineWeb.Plugs.InternalAPIAuth do
  @moduledoc """
  Shared-secret authentication for internal compatibility endpoints.
  """

  import Plug.Conn
  require Logger

  alias Elektrine.InternalAPI

  def init(opts) do
    opts
    |> Keyword.put_new(:env_names, ["PHOENIX_API_KEY"])
    |> Keyword.put_new(:param_names, [])
  end

  def call(conn, opts) do
    case configured_api_key(opts) do
      nil ->
        Logger.error("SECURITY: Internal API authentication configuration error")
        unauthorized(conn)

      expected_key ->
        case provided_key(conn, opts) do
          provided_key when is_binary(provided_key) ->
            if secure_compare(provided_key, expected_key) do
              conn
            else
              unauthorized(conn)
            end

          _ ->
            unauthorized(conn)
        end
    end
  end

  defp provided_key(conn, opts) do
    List.first(get_req_header(conn, "x-api-key")) ||
      authorization_key(conn) ||
      param_key(conn, opts)
  end

  defp param_key(conn, opts) do
    Enum.find_value(Keyword.get(opts, :param_names, []), fn name ->
      case conn.params[name] do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp authorization_key(conn) do
    case List.first(get_req_header(conn, "authorization")) do
      "Bearer " <> token -> if(Elektrine.Strings.present?(token), do: token, else: nil)
      "Basic " <> credentials -> basic_auth_password(credentials)
      _ -> nil
    end
  end

  defp basic_auth_password(credentials) do
    with {:ok, decoded} <- Base.decode64(credentials),
         [_, password] <- String.split(decoded, ":", parts: 2),
         true <- Elektrine.Strings.present?(password) do
      password
    else
      _ -> nil
    end
  end

  defp configured_api_key(opts) do
    opts |> Keyword.fetch!(:env_names) |> InternalAPI.api_key()
  end

  defp secure_compare(provided_key, expected_key) do
    byte_size(provided_key) == byte_size(expected_key) and
      Plug.Crypto.secure_compare(provided_key, expected_key)
  end

  defp unauthorized(conn) do
    conn
    |> send_resp(:unauthorized, "unauthorized")
    |> halt()
  end
end
