defmodule ElektrineWeb.Plugs.CustomDomain do
  @moduledoc """
  Plug that detects and routes custom domain requests to user profiles.

  When a request comes in for a custom domain (not z.org, elektrine.com, etc.),
  this plug looks up the domain in the database and sets assigns for routing
  to the correct user's profile.

  ## Assigns Set

  - `:custom_domain` - The custom domain hostname
  - `:subdomain_handle` - The user's handle (for profile routing)
  - `:custom_domain_user` - The user struct (preloaded)
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  # Known domains that should not be treated as custom domains
  @known_domains ~w(
    elektrine.com www.elektrine.com
    z.org www.z.org
    localhost
    example.com www.example.com
  )

  @known_suffixes ~w(
    .elektrine.com
    .z.org
    .localhost
    .local
    .test
    .fly.dev
    .example.com
  )

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    path = conn.request_path

    # Allow certain paths through regardless of host
    cond do
      # Health checks (for Fly.io internal health checks)
      path == "/health" ->
        conn

      # ActivityPub federation endpoints - must bypass custom domain lookup
      path == "/inbox" ->
        conn

      String.starts_with?(path, "/users/") ->
        conn

      String.starts_with?(path, "/relay") ->
        conn

      String.starts_with?(path, "/.well-known/") ->
        conn

      String.starts_with?(path, "/nodeinfo") ->
        conn

      String.starts_with?(path, "/c/") ->
        conn

      String.starts_with?(path, "/tags/") ->
        conn

      true ->
        handle_host_check(conn)
    end
  end

  defp handle_host_check(conn) do
    host = conn.host

    cond do
      # Known primary domains - pass through
      host in @known_domains ->
        conn

      # Known subdomains (handle.z.org) - pass through, handled by ProfileSubdomain plug
      Enum.any?(@known_suffixes, &String.ends_with?(host, &1)) ->
        conn

      # Custom domain - look it up
      true ->
        handle_custom_domain(conn, host)
    end
  end

  defp handle_custom_domain(conn, hostname) do
    case Elektrine.CustomDomains.get_active_domain(hostname) do
      %{user: user} = _domain ->
        Logger.debug("Custom domain #{hostname} matched to user #{user.handle}")

        conn
        |> assign(:custom_domain, hostname)
        |> assign(:subdomain_handle, user.handle)
        |> assign(:custom_domain_user, user)

      nil ->
        # Domain not found or not active
        Logger.debug("Custom domain #{hostname} not found or not active")

        # Check if domain exists but is pending
        case Elektrine.CustomDomains.get_domain(hostname) do
          %{status: status} when status != "active" ->
            # Domain exists but not active - show pending page
            conn
            |> put_status(503)
            |> Phoenix.Controller.put_view(ElektrineWeb.ErrorHTML)
            |> Phoenix.Controller.render("503.html",
              message: "This domain is being configured. Please try again later."
            )
            |> halt()

          _ ->
            # Domain not registered at all
            conn
            |> put_status(404)
            |> Phoenix.Controller.put_view(ElektrineWeb.ErrorHTML)
            |> Phoenix.Controller.render("404.html")
            |> halt()
        end
    end
  end
end
