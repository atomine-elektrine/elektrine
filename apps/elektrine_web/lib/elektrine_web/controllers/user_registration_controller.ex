defmodule ElektrineWeb.UserRegistrationController do
  use ElektrineWeb, :controller
  import Ecto.Query, warn: false

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
    captcha_token = Map.get(params, "cf-turnstile-response")
    captcha_answer = Map.get(params, "captcha_answer")
    via_tor = conn.assigns[:via_tor] || false
    require Logger

    # Check registration rate limit first
    case check_registration_rate_limit(remote_ip) do
      {:error, :rate_limit_exceeded} ->
        conn
        |> put_flash(
          :error,
          "Only one registration per week is allowed per IP address. Please try again next week."
        )
        |> redirect(to: ~p"/register")

      :ok ->
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

              result = Turnstile.verify(captcha_token, remote_ip)

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
                    |> Map.put("registration_ip", remote_ip)
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
                |> Map.put("registration_ip", remote_ip)
                |> Map.put("registered_via_onion", via_tor)

              case Accounts.create_user(user_params_with_ip) do
                {:ok, user} ->
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
    ip_string =
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded_ips | _] ->
          # X-Forwarded-For can contain multiple IPs, take the first one
          forwarded_ips
          |> String.split(",")
          |> List.first()
          |> String.trim()

        [] ->
          # Convert tuple IP to string format
          conn.remote_ip
          |> :inet.ntoa()
          |> to_string()
      end

    # Normalize IPv6 to /64 subnet to prevent rotation attacks
    normalize_ipv6_subnet(ip_string)
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

  # Registration rate limiting - multi-layer approach
  defp check_registration_rate_limit(ip_address) do
    # Layer 1: Check /64 limit (1 per week for residential networks)
    case check_subnet_rate_limit(ip_address, 1, :week) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        # Layer 2: Check /32 limit (3 per day for ISP-wide abuse prevention)
        ip_32 = normalize_ipv6_to_32(ip_address)
        check_subnet_rate_limit(ip_32, 3, :day)
    end
  end

  defp check_subnet_rate_limit(ip_address, limit, period) do
    start_time =
      case period do
        :week ->
          Date.utc_today()
          |> Date.beginning_of_week()
          |> Date.to_string()
          |> then(fn date -> "#{date} 00:00:00" end)
          |> NaiveDateTime.from_iso8601!()
          |> DateTime.from_naive!("Etc/UTC")

        :day ->
          DateTime.utc_now()
          |> DateTime.add(-24, :hour)
      end

    # For /32 checks, we need to match the prefix
    registration_count =
      if String.ends_with?(ip_address, "::/32") do
        # Extract the /32 prefix for LIKE matching
        prefix = String.replace_suffix(ip_address, "::/32", "")

        Elektrine.Accounts.User
        |> where([u], like(u.registration_ip, ^"#{prefix}%") and u.inserted_at >= ^start_time)
        |> Elektrine.Repo.aggregate(:count, :id)
      else
        Elektrine.Accounts.User
        |> where([u], u.registration_ip == ^ip_address and u.inserted_at >= ^start_time)
        |> Elektrine.Repo.aggregate(:count, :id)
      end

    if registration_count >= limit do
      {:error, :rate_limit_exceeded}
    else
      :ok
    end
  end

  # Normalize IPv6 to /32 for ISP-level rate limiting
  defp normalize_ipv6_to_32(ip_string) do
    if String.contains?(ip_string, ":") do
      # Strip off /64 suffix if present
      base_ip = String.replace_suffix(ip_string, "::/64", "")
      hextets = String.split(base_ip, ":")

      # Handle compressed notation
      expanded =
        if Enum.any?(hextets, &(&1 == "")) do
          parts_before = Enum.take_while(hextets, &(&1 != ""))
          parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
          zeros_needed = 8 - length(parts_before) - length(parts_after)
          parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after
        else
          hextets
        end

      # Take first 2 hextets for /32 subnet
      expanded
      |> Enum.take(2)
      |> Enum.join(":")
      |> Kernel.<>("::/32")
    else
      # IPv4 - return as-is
      ip_string
    end
  end
end
