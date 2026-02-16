defmodule Elektrine.Email.HeaderDecoderTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.HeaderDecoder

  describe "decode_mime_header/1" do
    test "handles nil and empty inputs" do
      assert HeaderDecoder.decode_mime_header(nil) == ""
      assert HeaderDecoder.decode_mime_header("") == ""
    end

    test "decodes RFC 2047 base64 headers" do
      assert HeaderDecoder.decode_mime_header("=?UTF-8?B?SGVsbG8=?=") == "Hello"
    end

    test "decodes RFC 2047 quoted-printable headers" do
      assert HeaderDecoder.decode_mime_header("=?UTF-8?Q?Ol=C3=A1?=") == "Olá"
    end

    test "normalizes malformed quoted headers" do
      assert HeaderDecoder.decode_mime_header("\"\"Hello\"\"") == "\"Hello\""
    end
  end
end
