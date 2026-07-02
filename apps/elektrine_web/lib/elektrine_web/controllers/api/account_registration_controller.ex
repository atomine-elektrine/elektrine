defmodule ElektrineWeb.API.AccountRegistrationController do
  @moduledoc """
  Public account registration endpoint for API-compatible clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias ElektrineWeb.AtominePow
  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.Plugs.APIAuth

  def create(conn, params) do
    remote_ip = ClientIP.client_ip(conn)
    via_tor = conn.assigns[:via_tor] || false
    attrs = registration_attrs(params, remote_ip, via_tor)

    with :ok <- verify_security_check(params, remote_ip, via_tor),
         {:ok, %User{} = user} <- register_user(attrs),
         {:ok, token} <- APIAuth.generate_token(user.id) do
      json(conn, registration_token_payload(user, token, params))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_registration", details: translate_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "registration_security_check_failed", reason: format_reason(reason)})
    end
  end

  defp register_user(attrs) do
    if Elektrine.System.invite_codes_enabled?() do
      Accounts.register_user_with_access(attrs)
    else
      Accounts.create_user(attrs)
    end
  end

  defp registration_attrs(params, remote_ip, via_tor) do
    %{
      "username" => source_param(params, "username"),
      "password" => source_param(params, "password"),
      "password_confirmation" =>
        source_param(params, "password_confirmation") || source_param(params, "password"),
      "invite_code" => source_param(params, "invite_code"),
      "registration_access_token" => source_param(params, "registration_access_token"),
      "agree_to_terms" => agreement_param(params),
      "registration_ip" => normalize_ipv6_subnet(remote_ip),
      "registered_via_onion" => via_tor
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp source_param(params, key) do
    Map.get(params, key) || Map.get(params, String.to_atom(key))
  end

  defp agreement_param(params) do
    value = source_param(params, "agree_to_terms") || source_param(params, "agreement")

    if value in [true, "true", "1", 1, "on"], do: "true", else: value
  end

  defp verify_security_check(params, _remote_ip, true) do
    captcha_token = source_param(params, "captcha_token")

    captcha_answer =
      source_param(params, "captcha_answer") || source_param(params, "captcha_solution")

    case Elektrine.Captcha.verify(captcha_token, captcha_answer) do
      :ok -> :ok
      error -> error
    end
  end

  defp verify_security_check(params, remote_ip, false) do
    if AtominePow.enabled?() do
      AtominePow.verify(source_param(params, "atomine_pow_token"), "registration", remote_ip)
      |> case do
        {:ok, :verified} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp registration_token_payload(%User{} = user, token, params) do
    %{
      access_token: token,
      token_type: "Bearer",
      scope: normalize_scope(params),
      created_at: DateTime.to_unix(DateTime.utc_now()),
      id: to_string(user.id),
      username: user.username
    }
  end

  defp normalize_scope(params) do
    params
    |> source_param("scope")
    |> case do
      value when is_binary(value) and value != "" ->
        value
        |> String.replace(",", " ")
        |> String.split(~r/\s+/, trim: true)
        |> Enum.join(" ")

      _ ->
        "read write follow"
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp format_reason(reason), do: reason |> inspect() |> String.trim_leading(":")

  defp normalize_ipv6_subnet(ip_string) when is_binary(ip_string) do
    if String.contains?(ip_string, ":") do
      hextets = String.split(ip_string, ":")

      if Enum.any?(hextets, &(&1 == "")) do
        parts_before = Enum.take_while(hextets, &(&1 != ""))
        parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
        zeros_needed = 8 - length(parts_before) - length(parts_after)
        expanded = parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after

        expanded
        |> Enum.take(4)
        |> Enum.join(":")
        |> Kernel.<>("::/64")
      else
        hextets
        |> Enum.take(4)
        |> Enum.join(":")
        |> Kernel.<>("::/64")
      end
    else
      ip_string
    end
  end

  defp normalize_ipv6_subnet(_), do: nil
end
