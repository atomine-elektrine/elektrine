defmodule Elektrine.Email.HeaderDecoder do
  @moduledoc """
  Shared MIME header decoding for inbound and outbound email pipelines.
  """

  alias Elektrine.Email.Receiver

  def decode_mime_header(nil), do: ""
  def decode_mime_header(""), do: ""

  def decode_mime_header(text) when is_binary(text) do
    text
    |> fix_malformed_header()
    |> Receiver.decode_mail_header()
    |> ensure_valid_utf8()
  end

  # Fix malformed quoted headers produced by some clients.
  defp fix_malformed_header(text) when is_binary(text) do
    text
    |> String.replace(~r/^""/, "\"")
    |> String.replace(~r/""$/, "\"")
    |> String.replace(~r/^"+"([^"]+)"/, "\"\\1\"")
    |> String.trim()
  end

  # Final UTF-8 guard so decoded headers are always safe to store/render.
  defp ensure_valid_utf8(text) when is_binary(text) do
    if String.valid?(text) do
      text
    else
      text
      |> String.codepoints()
      |> Enum.filter(&String.valid?/1)
      |> Enum.join()
    end
  end
end
