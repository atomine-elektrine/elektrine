defmodule ElektrineWeb.UserRegistrationController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Turnstile
  alias ElektrineWeb.UserAuth

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%User{})
    invite_codes_enabled = Elektrine.System.invite_codes_enabled?()
    render_registration(conn, changeset: changeset, invite_codes_enabled: invite_codes_enabled)
  end

  def create(conn, %{"user" => user_params} = params) do
    remote_ip = get_remote_ip(conn)
    registration_ip = normalize_ipv6_subnet(remote_ip)
    captcha_token = Map.get(params, "cf-turnstile-response")
    captcha_answer = Map.get(params, "captcha_answer")
    via_tor = conn.assigns[:via_tor] || false
    require Logger

    # Check if captcha should be skipped (dev/test mode)
    turnstile_config = Application.get_env(:elektrine, :turnstile) || []
    skip_captcha = Keyword.get(turnstile_config, :skip_verification, false)

    # Different captcha verification for Tor vs clearnet
    captcha_result =
      if skip_captcha do
        Logger.debug("Captcha verification skipped (dev/test mode)")
        {:ok, :verified}
      else
        if via_tor do
          # Verify server-side image captcha for Tor users
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
        else
          # Use Turnstile for clearnet users
          Logger.info(
            "Turnstile check: token_present=#{not is_nil(captcha_token)}, ip_present=#{not is_nil(remote_ip)}"
          )

          result = Turnstile.verify(captcha_token)

          verification_status =
            if match?({:ok, :verified}, result), do: "verified", else: "failed"

          Logger.info("Turnstile result: #{verification_status}")
          result
        end
      end

    # Verify captcha
    case captcha_result do
      {:ok, :verified} ->
        # Check if invite codes are enabled
        if Elektrine.System.invite_codes_enabled?() do
          # Validate invite code
          invite_code = Map.get(user_params, "invite_code", "")

          case Accounts.validate_invite_code(invite_code) do
            {:ok, _invite_code} ->
              # Add IP address and Tor registration status to user params
              user_params_with_ip =
                user_params
                |> Map.put("registration_ip", registration_ip)
                |> Map.put("registered_via_onion", via_tor)

              case Accounts.create_user(user_params_with_ip) do
                {:ok, user} ->
                  # Use the invite code
                  Accounts.use_invite_code(invite_code, user.id)

                  UserAuth.log_in_user(conn, user, %{},
                    flash: {:info, "User created successfully."}
                  )

                {:error, %Ecto.Changeset{} = changeset} ->
                  invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

                  render_registration(conn,
                    changeset: changeset,
                    invite_codes_enabled: invite_codes_enabled
                  )
              end

            {:error, reason} ->
              changeset =
                %User{}
                |> Accounts.change_user_registration(user_params)
                |> Ecto.Changeset.add_error(:invite_code, invite_code_error_message(reason))

              invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

              render_registration(conn,
                changeset: changeset,
                invite_codes_enabled: invite_codes_enabled
              )
          end
        else
          # Invite codes disabled, proceed with normal registration
          # Add IP address and Tor registration status to user params
          user_params_with_ip =
            user_params
            |> Map.put("registration_ip", registration_ip)
            |> Map.put("registered_via_onion", via_tor)

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
        # Log the error for debugging
        require Logger
        Logger.error("Turnstile verification failed: #{inspect(reason)}")

        changeset =
          %User{}
          |> Accounts.change_user_registration(user_params)
          |> Ecto.Changeset.add_error(:captcha, "Please complete the captcha verification")

        invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

        render_registration(conn,
          changeset: changeset,
          invite_codes_enabled: invite_codes_enabled
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

  defp render_registration(conn, assigns) do
    # Extract error message from changeset if present
    case Keyword.get(assigns, :changeset) do
      %Ecto.Changeset{} = changeset ->
        error_message = format_changeset_errors(changeset)

        conn
        |> put_flash(:error, error_message)
        |> redirect(to: ~p"/register")

      _ ->
        redirect(conn, to: ~p"/register")
    end
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} ->
      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
    |> Enum.map_join(". ", & &1)
    |> case do
      "" -> "Registration failed. Please check your input."
      msg -> msg
    end
  end

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
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

  defp invite_code_error_message(:invalid_code), do: "Invalid invite code"
  defp invite_code_error_message(:code_expired), do: "This invite code has expired"

  defp invite_code_error_message(:code_exhausted),
    do: "This invite code has reached its usage limit"

  defp invite_code_error_message(:code_inactive), do: "This invite code is no longer active"
  defp invite_code_error_message(_), do: "Invalid invite code"
end
