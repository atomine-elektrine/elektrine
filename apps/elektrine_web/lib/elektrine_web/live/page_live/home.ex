defmodule ElektrineWeb.PageLive.Home do
  use ElektrineWeb, :live_view

  require Logger

  alias Elektrine.HomeBlog
  alias Elektrine.Platform.Modules

  on_mount({ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user})

  def mount(_params, _session, socket) do
    blog_posts = HomeBlog.cached_posts()

    if connected?(socket) and blog_posts == [] do
      send(self(), :load_blog_posts)
    end

    {:ok,
     assign(socket,
       page_title: "Home",
       poster_image: home_random_image(),
       button_images: home_button_images(),
       platform_stats: load_platform_stats(),
       onion_host: onion_host(),
       blog_posts: blog_posts
     ), layout: false}
  end

  def handle_info(:load_blog_posts, socket) do
    {:noreply, assign(socket, blog_posts: HomeBlog.latest_posts())}
  end

  defp onion_host do
    host = ElektrineWeb.Layouts.tor_onion_host()
    if String.ends_with?(host, ".onion"), do: host
  end

  def render(assigns) do
    ~H"""
    <script nonce={ElektrineWeb.Plugs.SecurityHeaders.script_nonce()} type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "Elektrine",
        "url": "#{Domains.public_base_url()}"
      }
    </script>

    <div class="relative min-h-screen overflow-hidden text-base-content">
      <section class="relative flex min-h-[100dvh] flex-col bg-[#05070a]">
        <div id="home-poster-art" phx-update="ignore" class="absolute inset-0">
          <%= if @poster_image do %>
            <div
              class="absolute inset-0 bg-cover"
              style={"background-image: url('/images/home/#{URI.encode(@poster_image)}'); background-position: 50% 30%;"}
            >
            </div>
          <% else %>
            <div
              class="absolute inset-0"
              style="background: radial-gradient(circle at top, color-mix(in srgb, var(--color-primary) 14%, transparent), transparent 40%), radial-gradient(circle at 82% 18%, color-mix(in srgb, var(--color-secondary) 10%, transparent), transparent 24%);"
            >
            </div>
          <% end %>
        </div>
        <div
          class="pointer-events-none absolute inset-0"
          style="background: linear-gradient(90deg, rgba(5,7,10,0.93) 0%, rgba(5,7,10,0.72) 38%, rgba(5,7,10,0.18) 68%, rgba(5,7,10,0.12) 100%), linear-gradient(0deg, rgba(5,7,10,0.88) 0%, transparent 38%), linear-gradient(180deg, rgba(5,7,10,0.5) 0%, transparent 22%);"
        >
        </div>

        <header class="relative z-10 mx-auto w-full max-w-7xl px-6 py-8 sm:px-8 lg:px-10">
          <.link navigate={~p"/"} class="inline-flex items-center">
            <.elektrine_logo class="h-8 w-auto text-white sm:h-9" />
            <span class="sr-only">Elektrine</span>
          </.link>
        </header>

        <div class="relative z-10 mx-auto mt-auto w-full max-w-7xl px-6 pb-12 sm:px-8 lg:flex lg:items-end lg:justify-between lg:gap-16 lg:px-10">
          <div class="min-w-0">
            <p class="font-mono text-xs uppercase tracking-[0.3em] text-white/60">
              Elektrine
            </p>
            <h1 class="mt-4 max-w-3xl font-pixel text-4xl uppercase leading-[1.08] tracking-[0.1em] text-white sm:text-5xl lg:text-6xl text-balance">
              Own or <span class="text-white/60">be owned.</span>
            </h1>
            <p class="mt-5 max-w-xl text-sm leading-7 text-white/70 sm:text-base">
              Elektrine is a private, modular internet suite for people who want everyday
              services without ads, tracking, or dependence on closed providers. Use the
              hosted service, or run your own when you want full independence. Open source,
              licensed under the AGPLv3.
            </p>

            <div class="mt-7 flex flex-wrap items-center gap-3">
              <%= if @current_user do %>
                <.button
                  href={~p"/portal"}
                  size="lg"
                  class="rounded-none font-mono text-xs uppercase tracking-[0.14em]"
                >
                  {gettext("Portal")}
                </.button>
                <%= if Modules.enabled?(:email) do %>
                  <.button
                    href={~p"/email"}
                    variant="default"
                    size="lg"
                    class="rounded-none border-white/30 bg-transparent font-mono text-xs uppercase tracking-[0.14em] text-white hover:border-white/60 hover:bg-white/10"
                  >
                    {gettext("Email")}
                  </.button>
                <% end %>
                <%= if Modules.enabled?(:chat) do %>
                  <.button
                    href={~p"/chat"}
                    variant="default"
                    size="lg"
                    class="rounded-none border-white/30 bg-transparent font-mono text-xs uppercase tracking-[0.14em] text-white hover:border-white/60 hover:bg-white/10"
                  >
                    {gettext("Chat")}
                  </.button>
                <% end %>
                <.button
                  href={~p"/account"}
                  variant="default"
                  size="lg"
                  class="rounded-none border-white/30 bg-transparent font-mono text-xs uppercase tracking-[0.14em] text-white hover:border-white/60 hover:bg-white/10"
                >
                  {gettext("Account")}
                </.button>
                <.button
                  href={~p"/logout"}
                  method="delete"
                  variant="error"
                  size="lg"
                  class="rounded-none font-mono text-xs uppercase tracking-[0.14em]"
                >
                  {gettext("Sign out")}
                </.button>
              <% else %>
                <.button
                  href={~p"/register"}
                  size="lg"
                  class="rounded-none font-mono text-xs uppercase tracking-[0.14em]"
                >
                  {gettext("Sign up")}
                </.button>
                <.button
                  href={Elektrine.Paths.login_path()}
                  variant="default"
                  size="lg"
                  class="rounded-none border-white/30 bg-transparent font-mono text-xs uppercase tracking-[0.14em] text-white hover:border-white/60 hover:bg-white/10"
                >
                  {gettext("Sign in")}
                </.button>
              <% end %>
            </div>

            <div class="mt-8 max-w-2xl border-t border-white/15 pt-4">
              <div class="flex flex-wrap items-center gap-x-6 gap-y-2 font-mono text-2xs uppercase tracking-[0.14em] text-white/45">
                <span :if={@platform_stats.stats.users > 0}>
                  Users
                  <span class="font-pixel text-lg leading-none tabular-nums text-white/85">
                    {format_stat(@platform_stats.stats.users)}
                  </span>
                </span>
                <span :if={@platform_stats.federation.instances > 0}>
                  Instances
                  <span class="font-pixel text-lg leading-none tabular-nums text-white/85">
                    {format_stat(@platform_stats.federation.instances)}
                  </span>
                </span>
                <span :if={@platform_stats.stats.posts > 0}>
                  Posts
                  <span class="font-pixel text-lg leading-none tabular-nums text-white/85">
                    {format_stat(@platform_stats.stats.posts)}
                  </span>
                </span>
                <span :if={@platform_stats.federation.remote_actors > 0}>
                  Fediverse peers
                  <span class="font-pixel text-lg leading-none tabular-nums text-white/85">
                    {format_stat(@platform_stats.federation.remote_actors)}
                  </span>
                </span>
              </div>
              <div class="mt-3 flex flex-wrap items-center gap-4 text-sm text-white/50">
                <.link
                  href={github_repo_url()}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 hover:text-white"
                >
                  <.icon name="hero-code-bracket-mini" class="h-4 w-4" />
                  <span>GitHub</span>
                </.link>
                <.link
                  href={github_releases_url()}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 hover:text-white"
                >
                  <.icon name="hero-arrow-down-tray-mini" class="h-4 w-4" />
                  <span>Releases</span>
                </.link>
                <.link
                  href={github_issues_url()}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 hover:text-white"
                >
                  <.icon name="hero-exclamation-circle-mini" class="h-4 w-4" />
                  <span>Issues</span>
                </.link>
                <.link
                  :if={@onion_host}
                  href={"http://#{@onion_host}"}
                  rel="noopener noreferrer"
                  title={@onion_host}
                  class="inline-flex items-center gap-2 hover:text-white"
                >
                  <.icon name="hero-globe-alt-mini" class="h-4 w-4" />
                  <span>Onion service</span>
                </.link>
                <span :if={!@onion_host} class="inline-flex items-center gap-2 opacity-60">
                  <.icon name="hero-globe-alt-mini" class="h-4 w-4" />
                  <span>Onion: not configured</span>
                </span>
              </div>
            </div>
          </div>

          <aside
            :if={@blog_posts != []}
            class="mt-10 border border-white/10 bg-[#05070a]/85 p-4 backdrop-blur-sm lg:mt-0 lg:w-80 lg:shrink-0"
          >
            <p class="font-mono text-2xs uppercase tracking-[0.22em] text-white/40">
              // From the operator
            </p>
            <div class="mt-3 space-y-4">
              <.link
                :for={{post, index} <- Enum.with_index(@blog_posts)}
                href={post.url}
                target="_blank"
                rel="noopener noreferrer"
                class={["group block", index > 0 && "hidden lg:block"]}
              >
                <time
                  :if={post.published_at}
                  class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35"
                >
                  {Calendar.strftime(post.published_at, "%b %d, %Y")}
                </time>
                <p class="mt-0.5 text-sm leading-snug text-white/80 transition-colors group-hover:text-white">
                  {post.title}
                </p>
              </.link>
            </div>
            <.link
              href={HomeBlog.feed_url()}
              target="_blank"
              rel="noopener noreferrer"
              class="mt-4 inline-flex items-center gap-1.5 font-mono text-3xs uppercase tracking-[0.18em] text-white/40 transition-colors hover:text-white"
            >
              <.icon name="hero-rss-mini" class="h-3.5 w-3.5" />
              <span>Atom feed</span>
            </.link>
          </aside>
        </div>
      </section>

      <div class="border-t border-white/10 bg-[#05070a]">
        <main class="mx-auto max-w-7xl space-y-14 px-6 py-14 sm:px-8 lg:px-10">
          <section>
            <p class="font-mono text-xs uppercase tracking-[0.3em] text-white/40">
              // What you get
            </p>
            <div class="mt-8 space-y-10">
              <%= for group <- feature_groups() do %>
                <div>
                  <p class="font-mono text-2xs uppercase tracking-[0.22em] text-white/30">
                    {group.label}
                  </p>
                  <div class="mt-3 grid gap-px border border-white/10 bg-white/10 sm:grid-cols-2 lg:grid-cols-3">
                    <%= for item <- group.items do %>
                      <div class={[
                        "bg-[#05070a] px-4 py-3.5",
                        item[:wide] && "sm:col-span-2 lg:col-span-3"
                      ]}>
                        <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                          {item.tag}
                        </div>
                        <div class="mt-1 text-sm font-medium text-white/90">{item.title}</div>
                        <div class="mt-0.5 text-xs leading-relaxed text-white/50">{item.detail}</div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </section>

          <section>
            <p class="font-mono text-xs uppercase tracking-[0.3em] text-white/40">
              // For developers
            </p>
            <div class="mt-6 grid gap-px border border-white/10 bg-white/10 sm:grid-cols-2 lg:grid-cols-3">
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  Email API
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  Mail over HTTP
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Read, list, and send messages from your own scripts and software
                </div>
              </div>
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  JMAP
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  JMAP built in
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Alongside IMAP, POP3, and SMTP. Bring any client, or write one
                </div>
              </div>
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  Client API
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  Works with the apps you have
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Mastodon-compatible, so existing clients and libraries just connect
                </div>
              </div>
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  MCP
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  AI tools, scoped to you
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Connect Claude, Codex, or local agents to mail, Kairo, Nerve, and search
                  through scoped personal access tokens
                </div>
              </div>
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  OIDC
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  Sign in with your own domain
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Plain OpenID Connect for anything you build or run
                </div>
              </div>
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  Tokens
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  Scoped tokens
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Each script gets only the access it needs, read or write, per service
                </div>
              </div>
              <div class="bg-[#05070a] px-4 py-3.5">
                <div class="font-mono text-3xs uppercase tracking-[0.18em] text-white/35">
                  Deploys
                </div>
                <div class="mt-1 text-sm font-medium text-white/90">
                  Static sites
                </div>
                <div class="mt-0.5 text-xs leading-relaxed text-white/50">
                  Push a build and it's live, by hand or straight from your repository
                </div>
              </div>
            </div>
          </section>

          <%!-- 88x31 button wall (images/home/buttons/). --%>
          <section :if={@button_images != []} class="border border-white/10 p-4">
            <div class="flex flex-wrap justify-center gap-1.5">
              <img
                :for={button <- @button_images}
                src={~p"/images/home/buttons/#{button}"}
                alt=""
                width="88"
                height="31"
                class="h-[31px] w-[88px] shrink-0 [image-rendering:pixelated]"
                loading="lazy"
              />
            </div>
          </section>
        </main>

        <footer class="border-t border-white/10">
          <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-x-8 gap-y-3 px-6 py-6 sm:px-8 lg:px-10">
            <nav
              aria-label="Site information"
              class="flex flex-wrap items-center gap-x-5 gap-y-2 font-mono text-2xs uppercase tracking-[0.14em]"
            >
              <.link navigate={~p"/about"} class="text-white/45 transition-colors hover:text-white">
                About
              </.link>
              <.link navigate={~p"/contact"} class="text-white/45 transition-colors hover:text-white">
                Contact
              </.link>
              <.link navigate={~p"/faq"} class="text-white/45 transition-colors hover:text-white">
                FAQ
              </.link>
              <.link navigate={~p"/terms"} class="text-white/45 transition-colors hover:text-white">
                Terms of Service
              </.link>
              <.link navigate={~p"/privacy"} class="text-white/45 transition-colors hover:text-white">
                Privacy Policy
              </.link>
              <.link href={~p"/canary"} class="text-white/45 transition-colors hover:text-white">
                Canary
              </.link>
            </nav>
            <p class="font-mono text-2xs uppercase tracking-[0.14em] text-white/30">
              Elektrine · AGPLv3
            </p>
          </div>
        </footer>
      </div>
    </div>
    """
  end

  defp format_stat(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_stat(_), do: "0"

  defp feature_groups do
    [
      %{
        label: "Mail",
        items: [
          %{tag: "Aliases", title: "Free aliases", detail: "Up to 15 addresses at no extra cost"},
          %{
            tag: "Catch-all",
            title: "Catch-all & plus tags",
            detail: "anything@your-domain and you+tag@ just work"
          },
          %{
            tag: "Domains",
            title: "Free custom domains",
            detail: "Bring your own domain"
          },
          %{
            tag: "Clients",
            title: "Use any mail app",
            detail: "Works in Thunderbird and any IMAP, POP3, SMTP or JMAP client"
          },
          %{
            tag: "Deliverability",
            title: "Lands in the inbox",
            detail: "DKIM, SPF, and DMARC handled for you"
          },
          %{
            tag: "PGP",
            title: "PGP, built in",
            detail: "OpenPGP with automatic key discovery (WKD)"
          }
        ]
      },
      %{
        label: "Privacy & security",
        items: [
          %{
            tag: "First-party",
            title: "No third parties in the loop",
            detail:
              "No Cloudflare, no Google Analytics, no third-party trackers, fonts, or CDNs. Nothing phones home.",
            wide: true
          },
          %{
            tag: "Email",
            title: "Local email encryption",
            detail: "Keys stay in your browser, so the server only ever stores ciphertext"
          },
          %{
            tag: "Chat",
            title: "End-to-end encrypted chat",
            detail: "Messages are encrypted on your device, so the server only relays ciphertext"
          },
          %{
            tag: "Tor",
            title: "Works over Tor",
            detail: "Sign up and use Elektrine privately"
          },
          %{
            tag: "Passkeys",
            title: "Passwordless sign-in",
            detail:
              "Phishing-resistant WebAuthn across up to 10 devices, with no password to steal"
          },
          %{
            tag: "2FA",
            title: "Two-factor auth",
            detail: "TOTP protection on your account"
          },
          %{
            tag: "Signups",
            title: "No CAPTCHAs",
            detail: "A short background check stops bots, so you never solve puzzles"
          },
          %{
            tag: "Open source",
            title: "Open source (AGPLv3)",
            detail: "Audit it, or self-host the exact code we run"
          }
        ]
      },
      %{
        label: "Social and chat",
        items: [
          %{
            tag: "Fediverse",
            title: "On the fediverse",
            detail: "Follow and be followed across Mastodon, Lemmy, and more"
          },
          %{
            tag: "Bluesky",
            title: "Mirror to Bluesky",
            detail: "Crosspost your public timeline to Bluesky"
          },
          %{
            tag: "Messaging",
            title: "Federated messaging",
            detail: "Message and call across Elektrine servers, not just your own"
          }
        ]
      },
      %{
        label: "Beyond the inbox",
        items: [
          %{
            tag: "Knowledge",
            title: "Your knowledge base",
            detail:
              "Kairo ingests notes and sources into a durable, searchable knowledge graph you own"
          },
          %{
            tag: "Secrets",
            title: "Password & secrets manager",
            detail:
              "Nerve keeps passwords and secrets client-side encrypted, so the server only stores ciphertext"
          },
          %{
            tag: "Web search",
            title: "Private web search",
            detail:
              "Search the open web with Paige, which blends results from several engines and never profiles you"
          },
          %{
            tag: "Calendar",
            title: "Calendar & contacts",
            detail: "Sync everywhere with CalDAV and CardDAV"
          },
          %{
            tag: "Portability",
            title: "No lock-in",
            detail: "Export all your data over an open API, any time"
          }
        ]
      }
    ]
  end

  # Sidebar images live in priv/static/images/home/ (served at /images/home/...).
  # Top-level files are full-size images (one shown at random per page load);
  # 88x31 retro buttons go in the buttons/ subfolder and are all shown together.
  defp home_images_dir, do: Path.join(:code.priv_dir(:elektrine), "static/images/home")

  defp home_random_image do
    case home_sidebar_images() do
      [] -> nil
      images -> Enum.random(images)
    end
  end

  defp home_sidebar_images, do: list_images(home_images_dir())

  defp home_button_images, do: list_images(Path.join(home_images_dir(), "buttons"))

  # Format-agnostic listing: skips dotfiles, subdirectories, and the gzipped /
  # content-hashed copies that `mix phx.digest` produces, so any real image the
  # user drops in is included as-is.
  defp list_images(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(fn name ->
          String.starts_with?(name, ".") or
            String.ends_with?(name, ".gz") or
            Regex.match?(~r/-[a-f0-9]{32}\.[^.]+$/, name) or
            File.dir?(Path.join(dir, name))
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp github_repo_url, do: "https://github.com/atomine-elektrine/elektrine"

  defp github_releases_url, do: "https://github.com/atomine-elektrine/elektrine/releases"

  defp github_issues_url, do: "https://github.com/atomine-elektrine/elektrine/issues"

  def load_platform_stats(cache_fetch \\ &Elektrine.AppCache.get_platform_stats/1) do
    case cache_fetch.(&compute_platform_stats/0) do
      {:ok, stats} ->
        stats

      stats when is_map(stats) ->
        stats

      {:error, reason} ->
        Logger.warning("Home platform stats cache fetch failed: #{Exception.message(reason)}")
        default_platform_stats()
    end
  end

  defp compute_platform_stats do
    import Ecto.Query

    users = Elektrine.Repo.aggregate(Elektrine.Accounts.User, :count)

    posts =
      from(m in Elektrine.Social.Message,
        where: m.post_type in ["post", "gallery", "discussion"] and is_nil(m.deleted_at)
      )
      |> Elektrine.Repo.aggregate(:count)

    remote_actors = Elektrine.Repo.aggregate(Elektrine.ActivityPub.Actor, :count)

    instances =
      from(a in Elektrine.ActivityPub.Actor,
        where: not is_nil(a.domain),
        select: count(a.domain, :distinct)
      )
      |> Elektrine.Repo.one() || 0

    %{
      stats: %{users: users, emails: 0, posts: posts},
      federation: %{remote_actors: remote_actors, instances: instances}
    }
  end

  defp default_platform_stats do
    %{
      stats: %{users: 0, emails: 0, posts: 0},
      federation: %{remote_actors: 0, instances: 0}
    }
  end
end
