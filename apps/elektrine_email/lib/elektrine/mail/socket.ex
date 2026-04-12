defmodule Elektrine.Mail.Socket do
  @moduledoc false

  alias Elektrine.Constants
  require Logger

  def listen(:tcp, port, opts, _tls_opts), do: :gen_tcp.listen(port, opts)

  def listen(:ssl, port, opts, tls_opts) do
    ssl_opts = Enum.reject(opts, fn {key, _value} -> key == :packet end)

    :ssl.listen(
      port,
      ssl_opts ++
        [
          {:certfile, Keyword.fetch!(tls_opts, :certfile)},
          {:keyfile, Keyword.fetch!(tls_opts, :keyfile)},
          {:mode, :binary},
          {:verify, :verify_none},
          {:reuse_sessions, true},
          {:versions, [:"tlsv1.2", :"tlsv1.3"]}
        ]
    )
  end

  def accept(:tcp, socket), do: :gen_tcp.accept(socket)

  def accept(:ssl, socket) do
    Logger.info("Mail TLS accept: waiting for transport accept")

    case :ssl.transport_accept(socket) do
      {:ok, client} ->
        Logger.info("Mail TLS accept: transport accepted")
        {:ok, client}

      error ->
        Logger.error("Mail TLS accept: transport accept failed #{inspect(error)}")
        error
    end
  end

  def handshake(socket, timeout \\ Constants.mail_tls_handshake_timeout_ms()) do
    case :ssl.handshake(socket, timeout) do
      {:ok, tls_client} ->
        Logger.info("Mail TLS accept: handshake completed")
        {:ok, tls_client}

      :ok ->
        Logger.info("Mail TLS accept: handshake completed")
        {:ok, socket}

      error ->
        Logger.error("Mail TLS accept: handshake failed #{inspect(error)}")
        close(socket)
        error
    end
  end

  def send(socket, data) do
    case transport(socket) do
      :ssl -> :ssl.send(socket, data)
      :tcp -> :gen_tcp.send(socket, data)
    end
  end

  def recv(socket, length, timeout) do
    case transport(socket) do
      :ssl -> :ssl.recv(socket, length, timeout)
      :tcp -> :gen_tcp.recv(socket, length, timeout)
    end
  end

  def close(socket) do
    case transport(socket) do
      :ssl -> :ssl.close(socket)
      :tcp -> :gen_tcp.close(socket)
    end
  end

  def setopts(socket, opts) do
    case transport(socket) do
      :ssl -> :ssl.setopts(socket, opts)
      :tcp -> :inet.setopts(socket, opts)
    end
  end

  def peername(socket) do
    case transport(socket) do
      :ssl -> :ssl.peername(socket)
      :tcp -> :inet.peername(socket)
    end
  end

  defp transport(socket)
       when is_tuple(socket) and tuple_size(socket) > 0 and elem(socket, 0) == :sslsocket,
       do: :ssl

  defp transport(_socket), do: :tcp
end
