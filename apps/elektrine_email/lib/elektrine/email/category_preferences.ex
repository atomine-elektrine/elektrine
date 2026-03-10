defmodule Elektrine.Email.CategoryPreferences do
  @moduledoc """
  Persistence and lookup for learned sender/domain category preferences.
  """
  import Ecto.Query
  alias Elektrine.Email.CategoryPreference
  alias Elektrine.Repo

  @domain_learning_threshold 2

  @doc """
  Returns a learned category match for a sender, preferring exact sender over domain.

  Returns nil when no preference applies.
  """
  def match_category(user_id, from_email) when is_integer(user_id) and is_binary(from_email) do
    sender_email = extract_email(from_email)
    sender_domain = extract_domain(sender_email)

    if sender_email == "" do
      nil
    else
      case get_sender_preference(user_id, sender_email) do
        %CategoryPreference{} = preference ->
          %{
            category: preference.category,
            confidence: normalize_confidence(preference.confidence, 0.8),
            source: "learned_sender",
            reasons: ["learned sender preference for #{sender_email}"],
            learned_count: preference.learned_count
          }

        nil ->
          case get_domain_preference(user_id, sender_domain) do
            %CategoryPreference{learned_count: learned_count} = preference
            when learned_count >= @domain_learning_threshold ->
              %{
                category: preference.category,
                confidence: normalize_confidence(preference.confidence, 0.7),
                source: "learned_domain",
                reasons: ["learned domain preference for #{sender_domain}"],
                learned_count: learned_count
              }

            _ ->
              nil
          end
      end
    end
  end

  def match_category(_, _), do: nil

  @doc """
  Learns sender and domain preferences from a manual category move.
  """
  def learn_from_manual_move(user_id, from_email, category)
      when is_integer(user_id) and category in ["feed", "ledger"] do
    sender_email = extract_email(from_email)
    sender_domain = extract_domain(sender_email)

    cond do
      sender_email == "" ->
        {:error, :invalid_sender}

      sender_domain == "" ->
        upsert_preference(user_id, :email, sender_email, category)

      true ->
        with {:ok, _sender_pref} <- upsert_preference(user_id, :email, sender_email, category),
             {:ok, _domain_pref} <- upsert_preference(user_id, :domain, sender_domain, category) do
          :ok
        end
    end
  end

  def learn_from_manual_move(_, _, _), do: {:error, :invalid_category}

  defp get_sender_preference(user_id, email) do
    CategoryPreference
    |> where([p], p.user_id == ^user_id and p.email == ^email)
    |> Repo.one()
  end

  defp get_domain_preference(user_id, domain) do
    CategoryPreference
    |> where([p], p.user_id == ^user_id and p.domain == ^domain)
    |> Repo.one()
  end

  defp upsert_preference(user_id, :email, email, category) do
    case get_sender_preference(user_id, email) do
      %CategoryPreference{} = existing ->
        update_preference(existing, category, :email)

      nil ->
        create_preference(%{
          user_id: user_id,
          email: email,
          category: category,
          confidence: base_confidence(:email, 1),
          learned_count: 1,
          source: "manual_move",
          last_learned_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end

  defp upsert_preference(user_id, :domain, domain, category) do
    case get_domain_preference(user_id, domain) do
      %CategoryPreference{} = existing ->
        update_preference(existing, category, :domain)

      nil ->
        create_preference(%{
          user_id: user_id,
          domain: domain,
          category: category,
          confidence: base_confidence(:domain, 1),
          learned_count: 1,
          source: "manual_move",
          last_learned_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end

  defp create_preference(attrs) do
    %CategoryPreference{}
    |> CategoryPreference.changeset(attrs)
    |> Repo.insert()
  end

  defp update_preference(%CategoryPreference{} = existing, category, scope) do
    learned_count =
      if existing.category == category do
        existing.learned_count + 1
      else
        1
      end

    attrs = %{
      category: category,
      learned_count: learned_count,
      confidence: base_confidence(scope, learned_count),
      source: "manual_move",
      last_learned_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    existing
    |> CategoryPreference.changeset(attrs)
    |> Repo.update()
  end

  defp base_confidence(:email, learned_count) do
    min(0.95, 0.7 + (learned_count - 1) * 0.1)
  end

  defp base_confidence(:domain, learned_count) do
    min(0.9, 0.55 + (learned_count - 1) * 0.1)
  end

  defp normalize_confidence(confidence, default) when is_float(confidence) do
    confidence
    |> max(default)
    |> min(0.99)
    |> Float.round(3)
  end

  defp normalize_confidence(_, default), do: default

  defp extract_email(email_string) when is_binary(email_string) do
    extracted =
      case Regex.run(~r/<([^>]+)>/, email_string) do
        [_, email] -> String.trim(email)
        nil -> String.trim(email_string)
      end

    String.downcase(extracted)
  end

  defp extract_email(_), do: ""

  defp extract_domain(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_, domain] -> String.downcase(domain)
      _ -> ""
    end
  end

  defp extract_domain(_), do: ""
end
