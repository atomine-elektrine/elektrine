defmodule ElektrineWeb.Components.Profile.AccountExtras do
  @moduledoc """
  Profile page extras: account migration banner and featured (endorsed) accounts.
  """

  use ElektrineWeb, :html

  import ElektrineWeb.HtmlHelpers

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor

  attr :user, :map, required: true
  attr :base_url, :string, default: nil

  def moved_to_banner(assigns) do
    target = resolve_moved_to(assigns.user.moved_to)

    assigns =
      assigns
      |> assign(:target, target)
      |> assign(:target_href, moved_to_href(target, assigns.base_url))

    ~H"""
    <div class="mb-6 rounded-lg border border-warning/40 bg-warning/10 p-4 text-center">
      <div class="flex items-center justify-center gap-2 text-sm font-semibold text-[var(--profile-text)]">
        <.icon name="hero-arrow-right-circle" class="w-5 h-5 text-warning" />
        <span>
          {@user.display_name || @user.handle || @user.username} has moved to a new account
        </span>
      </div>
      <.button
        :if={@target_href}
        href={@target_href}
        rel="noopener noreferrer"
        variant="warning"
        size="sm"
        class="rounded-full mt-3"
      >
        {moved_to_label(@target)}
      </.button>
      <p :if={is_nil(@target_href)} class="mt-3 text-sm font-medium text-[var(--profile-text)]">
        {moved_to_label(@target)}
      </p>
    </div>
    """
  end

  attr :accounts, :list, required: true
  attr :base_url, :string, default: nil
  attr :is_default, :boolean, default: true

  def featured_accounts(%{accounts: []} = assigns), do: ~H""

  def featured_accounts(assigns) do
    ~H"""
    <div class="mb-8 w-full">
      <div class={
        if @is_default,
          do: "card panel-card rounded-lg p-3 sm:p-4",
          else: "bg-base-200/80 border border-base-300/70 rounded-lg p-3 sm:p-4"
      }>
        <div class="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-[var(--profile-text)] opacity-60 mb-3">
          <.icon name="hero-star" class="w-4 h-4" /> Featured Accounts
        </div>
        <div class="space-y-2">
          <%= for account <- @accounts do %>
            <%= if is_struct(account, User) do %>
              <.link
                href={profile_url(@base_url, "/#{account.handle || account.username}")}
                class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-300/60 transition-all"
              >
                <.user_avatar user={account} size="md" />
                <div class="flex-1 min-w-0 text-left">
                  <p class="font-medium truncate text-[var(--profile-text)]">
                    {raw(
                      render_display_name_with_emojis(
                        account.display_name || account.handle || account.username,
                        nil
                      )
                    )}
                  </p>
                  <p class="text-xs truncate text-[var(--profile-text)] opacity-60">
                    @{account.handle || account.username}@{Elektrine.Domains.default_user_handle_domain()}
                  </p>
                </div>
              </.link>
            <% else %>
              <.link
                href={profile_url(@base_url, "/remote/#{account.username}@#{account.domain}")}
                class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-300/60 transition-all"
              >
                <%= if avatar_url = safe_external_image_url(account.avatar_url) do %>
                  <img
                    src={avatar_url}
                    class="w-10 h-10 rounded-full object-cover"
                    alt={account.username}
                  />
                <% else %>
                  <.placeholder_avatar size="md" />
                <% end %>
                <div class="flex-1 min-w-0 text-left">
                  <p class="font-medium truncate text-[var(--profile-text)]">
                    {raw(
                      render_display_name_with_emojis(
                        account.display_name || account.username,
                        account.domain
                      )
                    )}
                  </p>
                  <p class="text-xs truncate text-[var(--profile-text)] opacity-60">
                    @{account.username}@{account.domain}
                  </p>
                </div>
              </.link>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp resolve_moved_to(uri) when is_binary(uri) do
    # Tolerates duplicate actor rows (returns the oldest) instead of raising
    # Ecto.MultipleResultsError like Repo.get_by would.
    case Elektrine.ActivityPub.get_actor_by_uri(uri) do
      %Actor{} = actor -> {:actor, actor}
      nil -> {:uri, uri}
    end
  end

  defp resolve_moved_to(_uri), do: {:uri, nil}

  defp moved_to_href({:actor, actor}, base_url),
    do: profile_url(base_url, "/remote/#{actor.username}@#{actor.domain}")

  # "acct:user@domain" values are accepted by the moved_to validation but are
  # not resolvable links; fall back to the conventional profile URL when the
  # identifier parses cleanly, otherwise render plain text (nil href).
  defp moved_to_href({:uri, "acct:" <> rest}, _base_url), do: acct_profile_url(rest)

  defp moved_to_href({:uri, uri}, _base_url), do: uri

  defp acct_profile_url(rest) do
    case String.split(rest, "@") do
      [user, domain] when user != "" and domain != "" ->
        if user =~ ~r/^[A-Za-z0-9._-]+$/ and domain =~ ~r/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/ do
          "https://#{domain}/@#{user}"
        end

      _ ->
        nil
    end
  end

  defp moved_to_label({:actor, actor}), do: "Go to @#{actor.username}@#{actor.domain}"
  defp moved_to_label({:uri, uri}), do: "Go to #{shorten_uri(uri)}"

  defp shorten_uri("acct:" <> rest), do: "@" <> rest

  defp shorten_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) -> host
      _ -> uri
    end
  end

  defp shorten_uri(_uri), do: "new account"
end
