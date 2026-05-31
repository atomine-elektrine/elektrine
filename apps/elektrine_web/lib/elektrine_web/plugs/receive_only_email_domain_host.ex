defmodule ElektrineWeb.Plugs.ReceiveOnlyEmailDomainHost do
  @moduledoc """
  Blocks web access for secondary email domains that are receive-only.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if receive_only_email_host?(conn.host) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:not_found, "Not found")
      |> halt()
    else
      conn
    end
  end

  defp receive_only_email_host?(host) when is_binary(host) do
    normalized_host =
      host
      |> String.downcase()
      |> String.split(":", parts: 2)
      |> List.first()

    Enum.any?(Elektrine.Domains.receive_only_email_domains(), fn domain ->
      normalized_host == domain or String.ends_with?(normalized_host, ".#{domain}")
    end)
  end

  defp receive_only_email_host?(_), do: false
end
