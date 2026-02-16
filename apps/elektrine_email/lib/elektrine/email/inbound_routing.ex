defmodule Elektrine.Email.InboundRouting do
  @moduledoc """
  Inbound recipient lookup and mailbox routing validation for Haraka webhook emails.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Email.Message
  alias Elektrine.Repo
  alias Elektrine.Accounts.User

  @doc """
  Resolves an inbound recipient to either:
  - `{:ok, mailbox}` for local delivery
  - `{:forward_external, target_email, alias_email}` for external alias/mailbox forwarding
  - `{:error, reason}` when no valid local recipient can be found
  """
  def resolve_recipient_mailbox(to, rcpt_to) do
    # Prefer envelope recipient for mailing-list delivery.
    clean_email =
      extract_local_email(rcpt_to, to) || extract_clean_email(rcpt_to) || extract_clean_email(to)

    if clean_email do
      normalized_email = Email.normalize_plus_address(clean_email)

      case Email.resolve_alias(clean_email) do
        target_email when is_binary(target_email) ->
          {:forward_external, target_email, clean_email}

        :no_forward ->
          find_main_mailbox_for_alias(clean_email)

        nil ->
          case find_existing_mailbox(normalized_email, normalized_email) do
            {:ok, mailbox} ->
              case Email.get_mailbox_forward_target(mailbox) do
                target_email when is_binary(target_email) ->
                  {:forward_external, target_email, clean_email}

                nil ->
                  {:ok, mailbox}
              end

            nil ->
              {:error, :no_mailbox}
          end
      end
    else
      {:error, :invalid_email}
    end
  end

  @doc """
  Validates that the inbound `to` / `rcpt_to` address set is allowed to route
  into the provided mailbox.
  """
  def validate_mailbox_route(to, rcpt_to, mailbox) do
    to_clean = extract_clean_email(to)
    rcpt_to_clean = extract_clean_email(rcpt_to)
    mailbox_clean = extract_clean_email(mailbox.email)

    to_normalized = to_clean && Email.normalize_plus_address(to_clean)
    rcpt_to_normalized = rcpt_to_clean && Email.normalize_plus_address(rcpt_to_clean)
    mailbox_normalized = mailbox_clean && Email.normalize_plus_address(mailbox_clean)

    matches_to =
      to_normalized && mailbox_normalized &&
        String.downcase(to_normalized) == String.downcase(mailbox_normalized)

    matches_rcpt_to =
      rcpt_to_normalized && mailbox_normalized &&
        String.downcase(rcpt_to_normalized) == String.downcase(mailbox_normalized)

    matches_alias = check_alias_ownership(to_clean || rcpt_to_clean, mailbox)

    cond do
      matches_to ->
        :ok

      matches_rcpt_to ->
        :ok

      matches_alias ->
        :ok

      true ->
        {:error,
         "Email address mismatch: TO=#{to_clean}, RCPT_TO=#{rcpt_to_clean}, Mailbox=#{mailbox.email}"}
    end
  end

  @doc """
  Returns true when an inbound envelope is actually an outbound/local submission
  (local sender -> external recipient) and should be ignored on inbound path.
  """
  def outbound_email?(from, to) do
    from_clean = extract_clean_email(from) || ""
    to_clean = extract_clean_email(to) || ""

    from_is_local = Enum.any?(supported_domains(), &String.contains?(from_clean, "@#{&1}"))
    to_is_local = Enum.any?(supported_domains(), &String.contains?(to_clean, "@#{&1}"))

    from_is_local && !to_is_local
  end

  @doc """
  Returns true when this inbound message appears to be a recent sent-message loopback.
  """
  def loopback_email?(from, to, subject) do
    from_clean = extract_clean_email(from) || ""
    to_clean = extract_clean_email(to) || ""

    sender_mailbox =
      Mailbox
      |> where([m], fragment("lower(?)", m.email) == ^String.downcase(from_clean))
      |> limit(1)
      |> Repo.one()

    recipient_mailbox =
      Mailbox
      |> where([m], fragment("lower(?)", m.email) == ^String.downcase(to_clean))
      |> limit(1)
      |> Repo.one()

    if sender_mailbox && recipient_mailbox do
      ten_minutes_ago = DateTime.utc_now() |> DateTime.add(-600, :second)

      recent_sent =
        Message
        |> where([m], m.mailbox_id == ^sender_mailbox.id)
        |> where([m], m.status == "sent")
        |> where([m], m.to == ^to or m.to == ^to_clean or ilike(m.to, ^"%#{to_clean}%"))
        |> where([m], m.subject == ^subject)
        |> where([m], m.inserted_at > ^ten_minutes_ago)
        |> limit(1)
        |> Repo.one()

      not is_nil(recent_sent)
    else
      false
    end
  end

  @doc """
  Extracts a clean email address from loose header-like input.
  """
  def extract_clean_email(nil), do: nil
  def extract_clean_email(""), do: nil

  def extract_clean_email(email) when is_binary(email) do
    email = String.trim(email)

    result =
      cond do
        Regex.match?(~r/<([^@>]+@[^>]+)>/, email) ->
          case Regex.run(~r/<([^@>]+@[^>]+)>/, email) do
            [_, clean] -> String.trim(clean)
            _ -> nil
          end

        Regex.match?(~r/.+<([^@>]+@[^>]+)>/, email) ->
          case Regex.run(~r/.+<([^@>]+@[^>]+)>/, email) do
            [_, clean] -> String.trim(clean)
            _ -> nil
          end

        Regex.match?(~r/^[^\s<>]+@[^\s<>]+$/, email) ->
          String.trim(email)

        Regex.match?(~r/([^\s<>,"']+@[^\s<>,"']+)/, email) ->
          case Regex.run(~r/([^\s<>,"']+@[^\s<>,"']+)/, email) do
            [_, clean] -> String.trim(clean)
            _ -> nil
          end

        String.contains?(email, "@") ->
          case Regex.run(~r/([^@\s]+@[^@\s]+)/, email) do
            [_, clean] -> String.trim(clean)
            _ -> nil
          end

        true ->
          nil
      end

    case result do
      nil ->
        nil

      clean when is_binary(clean) ->
        if String.match?(clean, ~r/^[^@\s]+@[^@\s]+$/) do
          String.downcase(clean)
        else
          nil
        end
    end
  end

  defp extract_local_email(primary, fallback) do
    primary_clean = extract_clean_email(primary)

    if primary_clean && local_domain?(primary_clean) do
      primary_clean
    else
      fallback_clean = extract_clean_email(fallback)

      if fallback_clean && local_domain?(fallback_clean) do
        fallback_clean
      else
        nil
      end
    end
  end

  defp local_domain?(email) do
    case String.split(email, "@") do
      [_local_part, domain] -> domain in supported_domains()
      _ -> false
    end
  end

  defp supported_domains do
    Application.get_env(:elektrine, :email)[:supported_domains] || ["elektrine.com", "z.org"]
  end

  defp find_existing_mailbox(to, rcpt_to) do
    clean_email = extract_clean_email(to) || extract_clean_email(rcpt_to)

    if clean_email do
      check_regular_mailboxes(clean_email)
    else
      nil
    end
  end

  defp check_regular_mailboxes(clean_email) do
    regular_mailbox =
      Mailbox |> where(email: ^clean_email) |> limit(1) |> Repo.one() ||
        Mailbox
        |> where([m], fragment("lower(?)", m.email) == ^String.downcase(clean_email))
        |> limit(1)
        |> Repo.one()

    if regular_mailbox do
      {:ok, regular_mailbox}
    else
      nil
    end
  end

  defp find_main_mailbox_for_alias(alias_email) do
    case Email.get_alias_by_email(alias_email) do
      %Email.Alias{user_id: user_id} when is_integer(user_id) ->
        case Email.get_user_mailbox(user_id) do
          %Email.Mailbox{} = mailbox -> {:ok, mailbox}
          nil -> {:error, :no_main_mailbox}
        end

      nil ->
        {:error, :alias_not_found}
    end
  end

  defp check_alias_ownership(nil, _mailbox), do: false
  defp check_alias_ownership(_email, nil), do: false

  defp check_alias_ownership(email_address, mailbox) do
    case Email.get_alias_by_email(email_address) do
      %Email.Alias{user_id: user_id, enabled: enabled} ->
        if mailbox.user_id == user_id do
          if enabled do
            true
          else
            alias_local_part =
              email_address |> String.split("@") |> List.first() |> String.downcase()

            user = Repo.get(User, user_id)
            user_username = if user, do: String.downcase(user.username), else: nil

            mailbox_local_part =
              mailbox.email |> String.split("@") |> List.first() |> String.downcase()

            alias_local_part == user_username or alias_local_part == mailbox_local_part
          end
        else
          false
        end

      _ ->
        false
    end
  end
end
