defmodule Elektrine.PasswordManager.Payloads do
  @moduledoc """
  Shared payload parsing helpers for the extracted vault surfaces.
  """

  def decode_setup_params(params) when is_map(params) do
    decode_payload_field(params, "encrypted_verifier", required: true)
  end

  def decode_setup_params(_params), do: {:error, :invalid_payload}

  def decode_encrypted_entry_params(params) when is_map(params) do
    case decode_payload_field(params, "encrypted_password", required: true) do
      {:ok, decoded_params} ->
        decode_payload_field(decoded_params, "encrypted_notes", required: false)

      error ->
        error
    end
  end

  def decode_encrypted_entry_params(_params), do: {:error, :invalid_payload}

  def encode_payload(nil), do: ""
  def encode_payload(payload) when is_map(payload), do: Jason.encode!(payload)

  defp decode_payload_field(params, field, opts) do
    required? = Keyword.get(opts, :required, false)

    case Map.get(params, field) do
      nil ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, params}

      "" ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, Map.put(params, field, nil)}

      value when is_map(value) ->
        {:ok, params}

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> {:ok, Map.put(params, field, decoded)}
          _ -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end
end
