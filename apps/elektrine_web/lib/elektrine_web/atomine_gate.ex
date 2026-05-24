defmodule ElektrineWeb.AtomineGate do
  @moduledoc """
  Atomine proof-of-work gate for edge-served HTML.

  This is the foundation for DNS/CDN bot protection: requests can be challenged
  before origin content is served, then cleared with a short host-bound cookie.
  """

  import Plug.Conn

  alias ElektrineWeb.AtominePow
  alias ElektrineWeb.Endpoint

  @cookie_name "_elektrine_atomine_gate"
  @salt "atomine gate clearance v1"
  @verify_path "/__atomine_gate/verify"
  @default_clearance_ttl_seconds 12 * 60 * 60

  def verify_path, do: @verify_path

  def enabled? do
    env_bool("ATOMINE_GATE_ENABLED", Keyword.get(config(), :enabled, false))
  end

  def authorize_static_request(conn, user, "text/html", response_path) do
    scope = user_scope(user.id)

    if challenge_required?(conn, scope) do
      {:challenge, challenge(conn, scope, response_path)}
    else
      {:ok, conn}
    end
  end

  def authorize_static_request(conn, _user, _content_type, _response_path), do: {:ok, conn}

  def authorize_edge_request(conn, origin, response_path) do
    scope = edge_scope(origin)

    if edge_gate_enabled?(origin) and challenge_required?(conn, scope) do
      {:challenge, challenge(conn, scope, response_path)}
    else
      {:ok, conn}
    end
  end

  def handle_verify(conn) do
    {conn, params} = verify_params(conn)
    scope = verify_scope(params)
    return_to = safe_return_to(params["return_to"])
    token = params["atomine_pow_token"]

    cond do
      not enabled?() ->
        send_verify_error(conn, "Atomine Gate is not enabled.")

      is_nil(scope) ->
        send_verify_error(conn, "Invalid protected site.")

      true ->
        case AtominePow.verify(token, audience(conn, scope), nonce(conn, scope)) do
          {:ok, :verified} ->
            conn
            |> put_clearance_cookie(scope)
            |> put_resp_header("location", return_to)
            |> send_resp(303, "")
            |> halt()

          {:error, _reason} ->
            send_verify_error(conn, "Security check failed. Please try again.")
        end
    end
  end

  defp challenge_required?(conn, scope) do
    enabled?() and html_method?(conn.method) and not clearance_valid?(conn, scope)
  end

  defp html_method?(method), do: method in ["GET", "HEAD"]

  defp clearance_valid?(_conn, nil), do: false

  defp clearance_valid?(conn, scope) do
    conn = fetch_cookies(conn)

    with token when is_binary(token) <- conn.cookies[@cookie_name],
         {:ok, %{"host" => host, "scope" => ^scope}} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: clearance_ttl_seconds()) do
      host == normalized_host(conn)
    else
      _ -> false
    end
  end

  defp put_clearance_cookie(conn, scope) do
    value =
      Phoenix.Token.sign(Endpoint, @salt, %{
        "host" => normalized_host(conn),
        "scope" => scope
      })

    put_resp_cookie(conn, @cookie_name, value,
      http_only: true,
      max_age: clearance_ttl_seconds(),
      same_site: "Lax",
      secure: conn.scheme == :https
    )
  end

  defp challenge(conn, scope, response_path) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
    )
    |> send_resp(403, challenge_html(conn, scope, response_path))
    |> halt()
  end

  defp challenge_html(_conn, scope, response_path) do
    difficulty = difficulty()
    return_to = html_escape(response_path)
    verify_path = html_escape(@verify_path)
    scope = html_escape(scope)

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Atomine Gate</title>
      <style>
        :root {
          color-scheme: dark;
          --base-100: #121214;
          --base-200: #1a1a1d;
          --base-300: #2a2a31;
          --base-content: #e5e2e1;
          --muted: rgba(229, 226, 225, .66);
          --primary: #5f87b8;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        * { box-sizing: border-box; }
        body {
          min-height: 100vh;
          margin: 0;
          background: var(--base-100);
          color: var(--base-content);
          display: grid;
          place-items: center;
          padding: 1rem;
        }
        main {
          width: min(38rem, 100%);
          border: 1px solid rgba(229, 226, 225, .12);
          border-radius: 1rem;
          background: var(--base-200);
          box-shadow: 0 18px 60px rgba(0,0,0,.28);
          overflow: hidden;
        }
        header {
          padding: 1rem 1.25rem;
          border-bottom: 1px solid rgba(229, 226, 225, .1);
          display: flex;
          justify-content: space-between;
          gap: 1rem;
          align-items: center;
        }
        .brand { font-weight: 800; letter-spacing: -.02em; }
        .badge {
          border: 1px solid rgba(95, 135, 184, .36);
          border-radius: 999px;
          color: #c7d8ed;
          background: rgba(95, 135, 184, .12);
          padding: .28rem .6rem;
          font-size: .75rem;
          font-weight: 700;
        }
        section { padding: 1.5rem 1.25rem 1.25rem; }
        h1 { margin: 0; font-size: clamp(1.65rem, 5vw, 2.35rem); line-height: 1.1; letter-spacing: -.035em; }
        p { margin: .75rem 0 0; color: var(--muted); line-height: 1.6; }
        form {
          margin-top: 1.35rem;
          display: flex;
          flex-wrap: wrap;
          align-items: center;
          gap: .75rem;
        }
        button {
          border: 1px solid color-mix(in srgb, var(--primary) 75%, white 15%);
          border-radius: 999px;
          background: var(--primary);
          color: #fff;
          padding: .72rem 1rem;
          font-weight: 800;
          cursor: pointer;
        }
        button:disabled { cursor: wait; opacity: .72; }
        button[hidden] { display: none; }
        small {
          color: var(--muted);
          font-size: .9rem;
        }
      </style>
    </head>
    <body>
      <main>
        <header>
          <div class="brand">Elektrine</div>
          <div class="badge">Atomine Gate</div>
        </header>
        <section>
          <h1>Checking your browser</h1>
          <p>This site is protected by Elektrine. Your browser will run a short local proof-of-work check before continuing.</p>
          <form id="atomine-gate-form" method="post" action="#{verify_path}">
            <input type="hidden" name="atomine_pow_token" id="atomine-pow-token">
            <input type="hidden" name="gate_scope" value="#{scope}">
            <input type="hidden" name="return_to" value="#{return_to}">
            <button type="submit" id="atomine-gate-button" hidden>Try again</button>
            <small id="atomine-gate-status">Preparing challenge...</small>
          </form>
        </section>
      </main>
      <script>
        const difficulty = #{difficulty};
        const statusEl = document.getElementById('atomine-gate-status');
        const tokenEl = document.getElementById('atomine-pow-token');
        const button = document.getElementById('atomine-gate-button');
        const form = document.getElementById('atomine-gate-form');
        let running = false;
        const setStatus = (message) => { statusEl.textContent = message; };

        form.addEventListener('submit', async (event) => {
          event.preventDefault();
          await runGateCheck();
        });

        window.addEventListener('DOMContentLoaded', () => { runGateCheck(); });

        async function runGateCheck() {
          if (running) return;
          if (tokenEl.value) { form.submit(); return; }
          running = true;
          button.disabled = true;
          button.hidden = true;
          try {
            setStatus('Preparing challenge...');
            const challengeResponse = await postJson('/api/atomine/pow/challenge', { difficulty });
            const challenge = challengeResponse.challenge;
            const actualDifficulty = Number.parseInt(challengeResponse.difficulty ?? difficulty, 10);
            setStatus('Checking browser...');
            const gateProof = await collectGateProof(challenge);
            setStatus('Running proof of work...');
            const solution = await solvePow(challenge, actualDifficulty, (attempts) => {
              setStatus(`Working... ${attempts.toLocaleString()} attempts`);
            });
            setStatus('Issuing Atomine token...');
            const tokenResponse = await postJson('/api/atomine/anonymous-tokens', { challenge, solution, gate_proof: gateProof });
            tokenEl.value = tokenResponse.token;
            setStatus('Verified. Continuing...');
            form.submit();
          } catch (_error) {
            tokenEl.value = '';
            running = false;
            button.disabled = false;
            button.hidden = false;
            setStatus('Security check failed. Please try again.');
          }
        }

        async function postJson(url, body) {
          const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
          const json = await response.json().catch(() => ({}));
          if (!response.ok) throw new Error(json.error || 'request failed');
          return json;
        }

        async function collectGateProof(challenge) {
          const checks = [
            measureBrowserCheck('layout.getComputedStyle', () => {
              const probe = document.createElement('div');
              probe.style.cssText = 'position:absolute;left:-9999px;width:37px;height:11px;padding:3px;display:block;';
              document.body.appendChild(probe);
              const style = window.getComputedStyle(probe);
              const ok = style.display === 'block' && style.width === '37px' && style.paddingLeft === '3px';
              probe.remove();
              return { ok };
            }),
            measureBrowserCheck('canvas.toDataURL', () => {
              const canvas = document.createElement('canvas');
              canvas.width = 16; canvas.height = 16;
              const ctx = canvas.getContext('2d');
              if (!ctx) return { ok: false };
              ctx.fillStyle = '#1f6feb'; ctx.fillRect(0, 0, 16, 16);
              const data = canvas.toDataURL('image/png');
              return { ok: data.startsWith('data:image/png;base64,'), bytes: data.length };
            }),
            measureBrowserCheck('event.isTrusted', () => {
              let trusted = null;
              const button = document.createElement('button');
              button.addEventListener('click', (event) => { trusted = event.isTrusted; }, { once: true });
              button.dispatchEvent(new MouseEvent('click', { bubbles: true }));
              return { ok: trusted === false, synthetic_trusted: trusted };
            }),
            measureBrowserCheck('navigator.webdriver', () => ({ ok: navigator.webdriver !== true, webdriver: navigator.webdriver === true })),
            measureBrowserCheck('dom.querySelector', () => {
              const id = `atomine-gate-${Math.random().toString(36).slice(2)}`;
              const probe = document.createElement('span');
              probe.id = id; probe.dataset.atomineBrowserProof = 'true';
              document.body.appendChild(probe);
              const ok = document.querySelector(`#${id}`)?.dataset.atomineBrowserProof === 'true';
              probe.remove();
              return { ok };
            })
          ];
          if (checks.some((check) => !check.ok)) throw new Error('browser instrumentation failed');
          return { version: 'atomine-gate-v1', layers: ['pow', 'browser_instrumentation'], browser_instrumentation: { challenge_hash: await sha256Base64Url(challenge), checks, signals: { user_agent_hash: await sha256Base64Url(navigator.userAgent || '') } } };
        }

        function measureBrowserCheck(name, fn) {
          const startedAt = performance.now();
          try { return { name, ok: false, duration_ms: Math.max(0, Math.round(performance.now() - startedAt)), ...(fn() || {}) }; }
          catch (error) { return { name, ok: false, duration_ms: Math.max(0, Math.round(performance.now() - startedAt)), error: error?.name || 'Error' }; }
        }

        async function solvePow(challenge, bits, onProgress) {
          const encoder = new TextEncoder();
          let nonce = 0;
          while (true) {
            const solution = String(nonce);
            const digest = await crypto.subtle.digest('SHA-256', encoder.encode(`${challenge}:${solution}`));
            if (leadingZeroBits(new Uint8Array(digest)) >= bits) return solution;
            nonce += 1;
            if (nonce % 1000 === 0) { onProgress(nonce); await new Promise((resolve) => setTimeout(resolve, 0)); }
          }
        }

        async function sha256Base64Url(value) {
          const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
          let binary = '';
          for (const byte of new Uint8Array(digest)) binary += String.fromCharCode(byte);
          return btoa(binary).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/g, '');
        }

        function leadingZeroBits(bytes) {
          let total = 0;
          for (const byte of bytes) {
            if (byte === 0) { total += 8; continue; }
            for (let bit = 7; bit >= 0; bit -= 1) {
              if ((byte & (1 << bit)) === 0) total += 1;
              else return total;
            }
          }
          return total;
        }
      </script>
    </body>
    </html>
    """
  end

  defp send_verify_error(conn, message) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(422, "<h1>Atomine Gate</h1><p>#{html_escape(message)}</p>")
    |> halt()
  end

  defp difficulty do
    "ATOMINE_GATE_DIFFICULTY"
    |> env_value(Keyword.get(config(), :difficulty, AtominePow.difficulty()))
    |> AtominePow.normalize_difficulty()
  end

  defp clearance_ttl_seconds do
    "ATOMINE_GATE_CLEARANCE_TTL_SECONDS"
    |> env_value(Keyword.get(config(), :clearance_ttl_seconds, @default_clearance_ttl_seconds))
    |> normalize_positive_int(@default_clearance_ttl_seconds)
  end

  defp audience(conn, scope), do: "atomine-gate:#{normalized_host(conn)}:#{scope}"
  defp nonce(conn, scope), do: "host:#{normalized_host(conn)}:scope:#{scope}"

  defp verify_scope(%{"gate_scope" => scope}) when is_binary(scope) do
    normalize_scope(scope)
  end

  defp verify_scope(%{"user_id" => user_id}) do
    case parse_user_id(user_id) do
      nil -> nil
      user_id -> user_scope(user_id)
    end
  end

  defp verify_scope(_params), do: nil

  defp verify_params(%Plug.Conn{params: %Plug.Conn.Unfetched{}} = conn) do
    conn = fetch_query_params(conn)

    body_params =
      if urlencoded_form?(conn) do
        case read_body(conn, length: 64_000) do
          {:ok, body, conn} ->
            {Plug.Conn.Query.decode(body), conn}

          {:more, _partial, conn} ->
            {%{}, conn}

          {:error, _reason} ->
            {%{}, conn}
        end
      else
        {%{}, conn}
      end

    {body_params, conn} = body_params
    {conn, Map.merge(conn.query_params, body_params)}
  end

  defp verify_params(conn), do: {conn, conn.params}

  defp urlencoded_form?(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        false

      content_type ->
        content_type
        |> String.downcase()
        |> String.starts_with?("application/x-www-form-urlencoded")
    end
  end

  defp user_scope(user_id), do: "user:#{user_id}"

  defp edge_scope(origin) do
    zone_id = origin_value(origin, :zone_id)
    record_id = origin_value(origin, :record_id)
    host = origin_value(origin, :host) || origin_value(origin, :origin_host)

    cond do
      not is_nil(zone_id) and not is_nil(record_id) -> "dns:#{zone_id}:#{record_id}"
      is_binary(host) and host != "" -> "dns:host:#{host}"
      true -> nil
    end
  end

  defp edge_gate_enabled?(origin), do: origin_value(origin, :atomine_gate) |> truthy?()

  defp origin_value(origin, key) when is_map(origin) do
    Map.get(origin, key) || Map.get(origin, Atom.to_string(key))
  end

  defp normalize_scope(scope) do
    scope = String.trim(scope)

    if scope != "" and String.length(scope) <= 256 do
      scope
    end
  end

  defp normalized_host(conn), do: String.downcase(conn.host || "")

  defp parse_user_id(value) when is_integer(value) and value > 0, do: value

  defp parse_user_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {user_id, ""} when user_id > 0 -> user_id
      _ -> nil
    end
  end

  defp parse_user_id(_value), do: nil

  defp safe_return_to(value) when is_binary(value) do
    value = String.trim(value)

    if String.starts_with?(value, "/") and not String.starts_with?(value, "//") and
         String.length(value) <= 2048 do
      value
    else
      "/"
    end
  end

  defp safe_return_to(_value), do: "/"

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_positive_int(_value, default), do: default

  defp html_escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp config, do: Application.get_env(:elektrine, :atomine_gate, []) || []

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> truthy?(default)
      "" -> truthy?(default)
      value -> truthy?(value)
    end
  end

  defp env_value(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
