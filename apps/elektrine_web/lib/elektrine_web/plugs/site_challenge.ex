defmodule ElektrineWeb.Plugs.SiteChallenge do
  @moduledoc """
  Optional site-wide Atomine proof-of-work challenge — "under attack" mode.

  When `ATOMINE_GATE_SITE_ENABLED` is true (or `config :elektrine,
  :atomine_gate, site_enabled: true`), anonymous browser requests to HTML
  routes are served the self-hosted Atomine PoW interstitial before the app
  renders anything. Passing the check sets the host-bound clearance cookie,
  after which requests flow normally until it expires.

  Passes through untouched:

    * signed-in sessions (they cleared the signup gate already)
    * clients that explicitly negotiate a machine format instead of HTML
      (ActivityPub `application/activity+json`, JSON, Atom/RSS) — federation
      and feed fetches on content-negotiated paths keep working
    * non-GET/HEAD requests, except the interstitial's own verify POST,
      which is handled here (this plug sits before CSRF protection, like
      the static-site gate)

  Off by default. Intended to be switched on during an attack, not left on:
  it also challenges legitimate crawlers and link-preview fetchers.
  """

  import Plug.Conn

  alias ElektrineWeb.AtomineGate

  @machine_accept_types [
    "application/activity+json",
    "application/ld+json",
    "application/json",
    "application/atom+xml",
    "application/rss+xml",
    "application/xrd+xml",
    "application/jrd+json"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not AtomineGate.site_enabled?() ->
        conn

      conn.method == "POST" and conn.request_path == AtomineGate.verify_path() ->
        AtomineGate.handle_verify(conn)

      conn.method not in ["GET", "HEAD"] ->
        conn

      signed_in?(conn) ->
        conn

      machine_client?(conn) ->
        conn

      true ->
        case AtomineGate.authorize_site_request(conn, return_path(conn)) do
          {:ok, conn} -> conn
          {:challenge, conn} -> conn
        end
    end
  end

  defp signed_in?(conn), do: is_binary(get_session(conn, :user_token))

  # A client that explicitly asks for a machine format (and not HTML) is a
  # federation peer, API consumer, or feed reader — never challenge those.
  # Browsers, and bots pretending to be browsers (`*/*`, no Accept header),
  # get challenged.
  defp machine_client?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] ->
        accept = String.downcase(accept)

        not String.contains?(accept, "text/html") and
          Enum.any?(@machine_accept_types, &String.contains?(accept, &1))

      [] ->
        false
    end
  end

  defp return_path(conn) do
    case conn.query_string do
      qs when qs in [nil, ""] -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end
end
