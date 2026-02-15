defmodule ElektrineWeb.LocaleController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  def switch(conn, %{"locale" => locale}) do
    supported_locales = ~w(en es fr de zh ja)

    # Validate locale
    locale = if locale in supported_locales, do: locale, else: "en"

    # Update user preference if logged in
    if user = conn.assigns[:current_user] do
      require Logger

      case Accounts.update_user_locale(user, locale) do
        {:ok, _updated_user} ->
          :ok

        {:error, changeset} ->
          Logger.error("Failed to update user locale: #{inspect(changeset.errors)}")
      end
    end

    # Store in session and redirect back
    referer = get_req_header(conn, "referer") |> List.first()
    redirect_path = safe_local_redirect_path(referer, conn.host)

    conn
    |> put_session(:locale, locale)
    |> put_flash(:info, "Language updated successfully")
    |> redirect(to: redirect_path)
  end

  # Handle missing locale parameter (bots, invalid requests)
  def switch(conn, _params) do
    require Logger
    ip_address = to_string(:inet_parse.ntoa(conn.remote_ip))
    Logger.warning("Invalid locale switch attempt from #{ip_address} without locale parameter")

    # Redirect to homepage with error
    conn
    |> put_flash(:error, "Invalid request")
    |> redirect(to: ~p"/")
  end

  defp safe_local_redirect_path(nil, _host), do: "/"

  defp safe_local_redirect_path(referer, expected_host) when is_binary(referer) do
    case URI.parse(referer) do
      %URI{scheme: scheme, host: ^expected_host} = uri when scheme in ["http", "https"] ->
        path = if uri.path in [nil, ""], do: "/", else: uri.path
        query = if uri.query, do: "?" <> uri.query, else: ""
        fragment = if uri.fragment, do: "#" <> uri.fragment, else: ""
        path <> query <> fragment

      _ ->
        "/"
    end
  end
end
