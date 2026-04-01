defmodule ElektrineWeb.UserSettingsEmailController do
  @moduledoc """
  Email-owned controller helpers used by the shared account settings controller.
  """

  alias Elektrine.Email
  alias Elektrine.Email.Mailbox

  def edit_password_assigns(user_id) do
    private_mailbox = Email.get_user_mailbox(user_id)

    %{
      private_mailbox: private_mailbox,
      private_mailbox_unlock_mode: Mailbox.private_storage_unlock_mode(private_mailbox)
    }
  end

  def decode_private_mailbox_rewrap(params) when is_map(params) do
    wrapped_private_key = Map.get(params, "private_mailbox_wrapped_private_key")
    verifier = Map.get(params, "private_mailbox_verifier")
    unlock_mode = Map.get(params, "private_mailbox_unlock_mode")

    if blank_string?(wrapped_private_key) and blank_string?(verifier) do
      {:ok, nil}
    else
      with {:ok, wrapped_private_key_payload} <- decode_json_payload(wrapped_private_key),
           {:ok, verifier_payload} <- decode_json_payload(verifier),
           true <- unlock_mode == "account_password" do
        {:ok,
         %{
           wrapped_private_key: wrapped_private_key_payload,
           verifier: verifier_payload,
           unlock_mode: unlock_mode
         }}
      else
        _ -> {:error, :invalid_private_mailbox_rewrap}
      end
    end
  end

  def decode_private_mailbox_rewrap(_params), do: {:ok, nil}

  defp decode_json_payload(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid}
    end
  end

  defp decode_json_payload(_value), do: {:error, :invalid}

  defp blank_string?(value) do
    !Elektrine.Strings.present?(value)
  end
end
