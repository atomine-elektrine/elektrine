defmodule ElektrineWeb.DomainAccountController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.AtomineProofBundle
  alias Elektrine.DomainAccount
  alias Elektrine.Domains
  alias Elektrine.Profiles

  def show(conn, _params) do
    case domain_account_for_host(conn.host) do
      {:ok, domain, user} ->
        json(
          conn,
          DomainAccount.document(user, domain,
            provider_base_url: Domains.public_base_url(),
            per_site_identities: Profiles.list_user_per_site_identities(user)
          )
        )

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "domain_account_not_found"})
    end
  end

  def did(conn, _params) do
    case domain_account_for_host(conn.host) do
      {:ok, domain, user} ->
        json(
          conn,
          DomainAccount.did_document(user, domain, provider_base_url: Domains.public_base_url())
        )

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "did_not_found"})
    end
  end

  def atomine(conn, _params) do
    case domain_account_for_host(conn.host) do
      {:ok, domain, user} ->
        json(
          conn,
          AtomineProofBundle.document(user, domain, provider_base_url: Domains.public_base_url())
        )

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "atomine_proof_bundle_not_found"})
    end
  end

  defp domain_account_for_host(host) when is_binary(host) do
    normalized_host = normalize_host(host)

    case Profiles.get_verified_custom_domain_for_host(normalized_host) do
      %{domain: domain, user: user} ->
        {:ok, domain, user}

      _ ->
        built_in_domain_account_for_host(normalized_host)
    end
  end

  defp domain_account_for_host(_), do: :error

  defp built_in_domain_account_for_host(host) do
    case Domains.profile_base_domain_for_host(host) do
      nil ->
        :error

      base_domain ->
        suffix = "." <> base_domain
        handle = String.trim_trailing(host, suffix)

        cond do
          handle == "" or String.contains?(handle, ".") ->
            :error

          user = Accounts.get_user_by_handle(handle) ->
            {:ok, host, user}

          true ->
            :error
        end
    end
  end

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.trim_leading("www.")
  end
end
