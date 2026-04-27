defmodule ElektrineWeb.UserRegistrationController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Turnstile
  alias ElektrineWeb.UserAuth

  def new(conn, _params), do: redirect(conn, to: ~p"/register")

  def create(conn, %{"user" => user_params} = params) do
    remote_ip = get_remote_ip(conn)
    registration_ip = normalize_ipv6_subnet(remote_ip)
    captcha_token = Map.get(params, "cf-turnstile-response")
    captcha_answer = Map.get(params, "captcha_answer")
    via_tor = conn.assigns[:via_tor] || false

    user_params_with_ip = registration_user_params(user_params, registration_ip, via_tor)
    preliminary_changeset = User.registration_changeset(%User{}, user_params_with_ip)

    if preliminary_changeset.valid? do
      captcha_result = verify_captcha(conn, captcha_token, captcha_answer, remote_ip, via_tor)
      complete_registration(conn, user_params_with_ip, captcha_result)
    else
      render_registration(conn,
        changeset: preliminary_changeset,
        invite_codes_enabled: Elektrine.System.invite_codes_enabled?()
      )
    end
  end

  # Catch-all for malformed/empty requests (bots, etc.)
  def create(conn, _params) do
    changeset = Accounts.change_user_registration(%User{})
    invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

    conn
    |> put_flash(:error, "Invalid registration request. Please fill out the form.")
    |> render_registration(changeset: changeset, invite_codes_enabled: invite_codes_enabled)
  end

  defp verify_captcha(conn, captcha_token, captcha_answer, remote_ip, via_tor) do
    require Logger

    turnstile_config = Application.get_env(:elektrine, :turnstile) || []

    if Keyword.get(turnstile_config, :skip_verification, false) do
      Logger.debug("Captcha verification skipped (dev/test mode)")
      {:ok, :verified}
    else
      verify_required_captcha(conn, captcha_token, captcha_answer, remote_ip, via_tor)
    end
  end

  defp verify_required_captcha(conn, _captcha_token, captcha_answer, _remote_ip, true) do
    require Logger

    token = get_session(conn, :captcha_token)

    Logger.info(
      "Tor captcha check: token_present=#{not is_nil(token)}, answer_present=#{not is_nil(captcha_answer)}"
    )

    if token && captcha_answer do
      case Elektrine.Captcha.verify(token, captcha_answer) do
        :ok -> {:ok, :verified}
        error -> error
      end
    else
      {:error, :missing_captcha}
    end
  end

  defp verify_required_captcha(_conn, captcha_token, _captcha_answer, remote_ip, false) do
    require Logger

    Logger.info(
      "Turnstile check: token_present=#{not is_nil(captcha_token)}, ip_present=#{not is_nil(remote_ip)}"
    )

    result = Turnstile.verify(captcha_token, turnstile_remote_ip(remote_ip))

    verification_status =
      if match?({:ok, :verified}, result), do: "verified", else: "failed"

    Logger.info("Turnstile result: #{verification_status}")
    result
  end

  defp complete_registration(conn, user_params_with_ip, captcha_result) do
    case captcha_result do
      {:ok, :verified} ->
        if Elektrine.System.invite_codes_enabled?() do
          case Accounts.register_user_with_access(user_params_with_ip) do
            {:ok, user} ->
              UserAuth.log_in_user(conn, user, %{}, flash: {:info, "User created successfully."})

            {:error, %Ecto.Changeset{} = changeset} ->
              invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

              render_registration(conn,
                changeset: changeset,
                invite_codes_enabled: invite_codes_enabled
              )
          end
        else
          case Accounts.create_user(user_params_with_ip) do
            {:ok, user} ->
              UserAuth.log_in_user(conn, user, %{}, flash: {:info, "User created successfully."})

            {:error, %Ecto.Changeset{} = changeset} ->
              invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

              render_registration(conn,
                changeset: changeset,
                invite_codes_enabled: invite_codes_enabled
              )
          end
        end

      {:error, reason} ->
        require Logger

        if reason in [:missing_token, :missing_captcha] do
          Logger.warning("Captcha verification missing: #{inspect(reason)}")
        else
          Logger.error("Captcha verification failed: #{inspect(reason)}")
        end

        changeset =
          %User{}
          |> Accounts.change_user_registration(user_params_with_ip)
          |> Ecto.Changeset.add_error(:captcha, captcha_error_message(reason))

        invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

        render_registration(conn,
          changeset: changeset,
          invite_codes_enabled: invite_codes_enabled
        )
    end
  end

  defp render_registration(conn, assigns) do
    case Keyword.get(assigns, :changeset) do
      %Ecto.Changeset{} = changeset ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_layout(false)
        |> Phoenix.LiveView.Controller.live_render(ElektrineWeb.AuthLive.Register,
          session: registration_live_session(conn, changeset)
        )

      _ ->
        redirect(conn, to: ~p"/register")
    end
  end

  defp registration_live_session(conn, changeset) do
    %{
      "via_tor" => conn.assigns[:via_tor] || false,
      "registration_form" => registration_form_data(changeset),
      "registration_errors" => registration_error_data(changeset),
      "registration_access_token" =>
        get_in(changeset.params || %{}, ["registration_access_token"])
    }
  end

  defp registration_form_data(%Ecto.Changeset{} = changeset) do
    changeset
    |> Map.get(:params, %{})
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["password", "password_confirmation"])
  end

  defp registration_error_data(%Ecto.Changeset{} = changeset) do
    Enum.reduce(changeset.errors, %{}, fn {field, error}, acc ->
      message = interpolate_error_message(error)
      Map.update(acc, Atom.to_string(field), [message], &[message | &1])
    end)
    |> Enum.into(%{}, fn {field, messages} -> {field, Enum.reverse(messages)} end)
  end

  defp interpolate_error_message({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  defp captcha_error_message({:verification_failed, error_codes}) when is_list(error_codes) do
    cond do
      "timeout-or-duplicate" in error_codes ->
        "The captcha expired. Please complete a fresh captcha verification."

      "invalid-input-response" in error_codes or "missing-input-response" in error_codes ->
        "Please complete the captcha verification."

      true ->
        "Captcha verification failed. Please try again."
    end
  end

  defp captcha_error_message(:missing_token), do: "Please complete the captcha verification"
  defp captcha_error_message(:missing_captcha), do: "Please complete the captcha verification"
  defp captcha_error_message(_reason), do: "Captcha verification failed. Please try again."

  defp turnstile_remote_ip(ip) when is_binary(ip) do
    with false <- ip in ["", "unknown"],
         {:ok, parsed_ip} <- :inet.parse_address(String.to_charlist(ip)),
         true <- public_ip?(parsed_ip) do
      ip
    else
      _ -> nil
    end
  end

  defp turnstile_remote_ip(_ip), do: nil

  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({a, b, _, _}) when a == 100 and b >= 64 and b <= 127, do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({_, _, _, _}), do: true
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFE00) == 0xFC00, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFE80, do: false
  defp public_ip?({_, _, _, _, _, _, _, _}), do: true

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp registration_user_params(user_params, registration_ip, via_tor) do
    user_params
    |> Map.put("registration_ip", registration_ip)
    |> Map.put("registered_via_onion", via_tor)
  end

  # Normalizes IPv6 addresses to /64 subnet (first 4 hextets)
  # This prevents brute-force attacks using IPv6 address rotation
  # Example: 2001:db8:1234:5678::1 -> 2001:db8:1234:5678::/64
  defp normalize_ipv6_subnet(ip_string) do
    if String.contains?(ip_string, ":") do
      # IPv6 address - normalize to /64 subnet
      hextets = String.split(ip_string, ":")

      # Handle compressed notation (::)
      if Enum.any?(hextets, &(&1 == "")) do
        # Expand :: to appropriate number of 0s
        parts_before = Enum.take_while(hextets, &(&1 != ""))
        parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
        zeros_needed = 8 - length(parts_before) - length(parts_after)
        expanded = parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after

        # Take first 4 hextets for /64 subnet
        expanded
        |> Enum.take(4)
        |> Enum.join(":")
        |> Kernel.<>("::/64")
      else
        # Not compressed - just take first 4 hextets
        hextets
        |> Enum.take(4)
        |> Enum.join(":")
        |> Kernel.<>("::/64")
      end
    else
      # IPv4 address - return as-is
      ip_string
    end
  end
end
