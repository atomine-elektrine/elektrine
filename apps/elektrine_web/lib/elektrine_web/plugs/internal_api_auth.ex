defmodule ElektrineWeb.Plugs.InternalAPIAuth do
  @moduledoc """
  Shared-secret authentication for internal compatibility endpoints.
  """

  import Plug.Conn
  require Logger

  def init(opts) do
    Keyword.put_new(opts, :env_names, ["PHOENIX_API_KEY"])
  end

  def call(conn, opts) do
    case configured_api_key(opts) do
      nil ->
        Logger.error("SECURITY: Internal API authentication configuration error")
        unauthorized(conn)

      expected_key ->
        case List.first(get_req_header(conn, "x-api-key")) do
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

  defp configured_api_key(opts) do
    opts
    |> Keyword.fetch!(:env_names)
    |> Enum.find_value(fn env_name ->
      case System.get_env(env_name) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
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
