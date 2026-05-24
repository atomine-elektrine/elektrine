defmodule ElektrineWeb.OnboardingLive do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses
  alias Elektrine.Profiles

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Redirect if already completed onboarding
    if user.onboarding_completed do
      {:ok, push_navigate(socket, to: Elektrine.Paths.chat_root_path())}
    else
      {:ok,
       socket
       |> assign(:step, user.onboarding_step || 1)
       |> assign(:total_steps, 4)
       |> assign(:bio, "")
       |> assign(:handle, user.handle || user.username)
       |> assign(:handle_error, nil)
       |> assign(:handle_changed, false)
       |> assign(:avatar_uploaded, false)}
    end
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    new_step = min(socket.assigns.step + 1, socket.assigns.total_steps)

    # Update user's onboarding step
    socket.assigns.current_user
    |> Elektrine.Accounts.User.changeset(%{onboarding_step: new_step})
    |> Elektrine.Repo.update()

    {:noreply, assign(socket, :step, new_step)}
  end

  @impl true
  def handle_event("prev_step", _params, socket) do
    new_step = max(socket.assigns.step - 1, 1)
    {:noreply, assign(socket, :step, new_step)}
  end

  @impl true
  def handle_event("skip_onboarding", _params, socket) do
    complete_onboarding(socket)
  end

  @impl true
  def handle_event("complete_onboarding", _params, socket) do
    complete_onboarding(socket)
  end

  @impl true
  def handle_event("update_bio", %{"value" => bio}, socket) do
    {:noreply, assign(socket, :bio, bio)}
  end

  @impl true
  def handle_event("update_handle", %{"value" => handle}, socket) do
    {:noreply, assign(socket, handle: handle, handle_changed: true, handle_error: nil)}
  end

  @impl true
  def handle_event("save_profile", _params, socket) do
    bio = socket.assigns.bio

    fresh_user = Elektrine.Repo.get!(Elektrine.Accounts.User, socket.assigns.current_user.id)

    bio_result =
      if Elektrine.Strings.present?(bio) do
        Profiles.upsert_user_profile(fresh_user.id, %{description: bio})
      else
        {:ok, nil}
      end

    case bio_result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:current_user, fresh_user)
         |> put_flash(:info, "Profile saved.")
         |> assign(:step, 3)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:current_user, fresh_user)
         |> put_flash(:info, "Profile step saved.")
         |> assign(:step, 3)}
    end
  end

  # Catch-all for unhandled events (e.g., device_detected from JS hooks)
  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp complete_onboarding(socket) do
    socket.assigns.current_user
    |> Elektrine.Accounts.User.changeset(%{
      onboarding_completed: true,
      onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Elektrine.Repo.update()

    {:noreply,
     socket
     |> put_flash(:info, "Onboarding complete.")
     |> push_navigate(to: Elektrine.Paths.chat_root_path())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl px-2 sm:px-4 lg:px-8 pb-8">
      <div class="card panel-card mt-6">
        <div class="card-body p-6 sm:p-8">
          <div class="mb-8">
            <div class="flex justify-between mb-2">
              <span class="text-sm font-medium">Step {@step} of {@total_steps}</span>
              <span class="text-sm opacity-70">{round(@step / @total_steps * 100)}% complete</span>
            </div>
            <progress class="progress progress-primary w-full" value={@step} max={@total_steps}>
            </progress>
          </div>

          <%= case @step do %>
            <% 1 -> %>
              <div>
                <div class="mb-8 text-center">
                  <p class="text-sm font-semibold uppercase tracking-wide text-primary mb-2">
                    Account basics
                  </p>
                  <h1 class="text-3xl font-bold mb-3">Keep these identifiers handy</h1>
                  <p class="text-base opacity-70 max-w-2xl mx-auto">
                    These are the names and addresses other people, apps, and mail clients use to reach you.
                  </p>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div class="p-4 bg-base-200 border border-base-300 rounded-lg">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-identification" class="w-5 h-5 text-primary" />
                      <h3 class="font-semibold">Login username</h3>
                    </div>
                    <p class="font-mono text-sm break-all">{@current_user.username}</p>
                    <p class="text-xs opacity-70 mt-2">Use this when signing in.</p>
                  </div>

                  <div class="p-4 bg-base-200 border border-base-300 rounded-lg">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-envelope" class="w-5 h-5 text-primary" />
                      <h3 class="font-semibold">Primary email</h3>
                    </div>
                    <p class="font-mono text-sm break-all">
                      {EmailAddresses.primary_for_user(@current_user)}
                    </p>
                    <p class="text-xs opacity-70 mt-2">
                      Local mail is available in webmail and standard mail clients.
                    </p>
                  </div>

                  <div class="p-4 bg-base-200 border border-base-300 rounded-lg">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-at-symbol" class="w-5 h-5 text-primary" />
                      <h3 class="font-semibold">Public handle</h3>
                    </div>
                    <p class="font-mono text-sm break-all">
                      @{@current_user.handle || @current_user.username}
                    </p>
                    <p class="text-xs opacity-70 mt-2">
                      This is your public profile and federation identifier.
                    </p>
                  </div>

                  <div class="p-4 bg-base-200 border border-base-300 rounded-lg">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-link" class="w-5 h-5 text-primary" />
                      <h3 class="font-semibold">Profile path</h3>
                    </div>
                    <p class="font-mono text-sm break-all">
                      /{@current_user.handle || @current_user.username}
                    </p>
                    <p class="text-xs opacity-70 mt-2">
                      Share this path when you want people to find your profile directly.
                    </p>
                  </div>
                </div>

                <div class="alert alert-info mt-6">
                  <.icon name="hero-information-circle" class="w-5 h-5" />
                  <div>
                    <p class="font-medium">Available mail domains</p>
                    <p class="text-xs opacity-80">
                      {Enum.map_join(
                        Elektrine.Domains.supported_email_domains(),
                        ", ",
                        fn domain -> "@" <> domain end
                      )}
                    </p>
                  </div>
                </div>
              </div>
            <% 2 -> %>
              <div>
                <div class="mb-8 text-center">
                  <p class="text-sm font-semibold uppercase tracking-wide text-primary mb-2">
                    Public profile
                  </p>
                  <h2 class="text-2xl font-bold mb-3">Add only what you want public</h2>
                  <p class="opacity-70 max-w-2xl mx-auto">
                    Your profile is optional. Add a short bio now, or leave it blank and configure the full profile editor later.
                  </p>
                </div>

                <div class="space-y-6">
                  <div class="flex flex-col items-center mb-6">
                    <div class="w-24 h-24 bg-primary/10 border-2 border-primary/20 rounded-full flex items-center justify-center text-primary text-3xl font-bold mb-3">
                      {String.first(String.upcase(@current_user.username))}
                    </div>
                    <p class="text-sm opacity-70">
                      Avatar and profile files are managed in profile settings.
                    </p>
                  </div>

                  <div class="form-control w-full">
                    <label class="label">
                      <span class="label-text font-medium">Username</span>
                    </label>
                    <input
                      type="text"
                      value={@current_user.username}
                      class="input input-bordered w-full"
                      disabled
                    />
                    <label class="label">
                      <span class="label-text-alt">
                        Login credential. Primary email: {EmailAddresses.primary_for_user(
                          @current_user
                        )}
                      </span>
                    </label>
                  </div>

                  <div class="form-control w-full">
                    <label class="label">
                      <span class="label-text font-medium">Handle</span>
                    </label>
                    <input
                      type="text"
                      value={@current_user.handle || @current_user.username}
                      class="input input-bordered w-full bg-base-200 text-base-content/70 cursor-not-allowed"
                      disabled
                      maxlength="20"
                    />
                    <label class="label">
                      <span class="label-text-alt">
                        Permanent public handle: @{@current_user.handle || @current_user.username}
                      </span>
                    </label>
                  </div>

                  <div class="form-control w-full">
                    <label class="label">
                      <span class="label-text font-medium">Bio (Optional)</span>
                    </label>
                    <textarea
                      placeholder="Short note shown on your public profile."
                      class="textarea textarea-bordered w-full h-24"
                      phx-keyup="update_bio"
                      name="bio"
                      maxlength="500"
                      phx-debounce="300"
                    ><%= @bio %></textarea>
                    <label class="label">
                      <span class="label-text-alt">{String.length(@bio)}/500 characters</span>
                    </label>
                  </div>

                  <div class="alert bg-base-200 border-base-300">
                    <.icon name="hero-pencil-square" class="w-5 h-5" />
                    <div>
                      <p class="font-medium">More profile controls are available later</p>
                      <p class="text-xs opacity-70">
                        Use profile settings for display details, files, and custom profile content.
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            <% 3 -> %>
              <div>
                <div class="mb-8 text-center">
                  <p class="text-sm font-semibold uppercase tracking-wide text-primary mb-2">
                    Recommended checks
                  </p>
                  <h2 class="text-2xl font-bold mb-3">Review these after signup</h2>
                  <p class="opacity-70 max-w-2xl mx-auto">
                    You do not need to configure everything now, but these settings are worth checking before you rely on the account.
                  </p>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <.link
                    navigate={~p"/account?tab=security"}
                    class="block p-5 bg-base-200 border border-base-300 rounded-lg hover:border-primary/40 transition-colors"
                  >
                    <div class="flex items-start gap-3">
                      <.icon name="hero-shield-check" class="w-6 h-6 text-primary mt-1" />
                      <div>
                        <h3 class="font-semibold mb-1">Security</h3>
                        <p class="text-sm opacity-70">
                          Add a recovery email, enable two-factor auth, and review passkeys or app passwords.
                        </p>
                      </div>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/account?tab=email"}
                    class="block p-5 bg-base-200 border border-base-300 rounded-lg hover:border-primary/40 transition-colors"
                  >
                    <div class="flex items-start gap-3">
                      <.icon name="hero-envelope" class="w-6 h-6 text-primary mt-1" />
                      <div>
                        <h3 class="font-semibold mb-1">Email delivery</h3>
                        <p class="text-sm opacity-70">
                          Check aliases, client access, signatures, PGP, and private mailbox options.
                        </p>
                      </div>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/account?tab=privacy"}
                    class="block p-5 bg-base-200 border border-base-300 rounded-lg hover:border-primary/40 transition-colors"
                  >
                    <div class="flex items-start gap-3">
                      <.icon name="hero-lock-closed" class="w-6 h-6 text-primary mt-1" />
                      <div>
                        <h3 class="font-semibold mb-1">Privacy</h3>
                        <p class="text-sm opacity-70">
                          Confirm profile visibility, federation behavior, and media/privacy preferences.
                        </p>
                      </div>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/account?tab=notifications"}
                    class="block p-5 bg-base-200 border border-base-300 rounded-lg hover:border-primary/40 transition-colors"
                  >
                    <div class="flex items-start gap-3">
                      <.icon name="hero-bell" class="w-6 h-6 text-primary mt-1" />
                      <div>
                        <h3 class="font-semibold mb-1">Notifications</h3>
                        <p class="text-sm opacity-70">
                          Decide which account, social, and email events should interrupt you.
                        </p>
                      </div>
                    </div>
                  </.link>
                </div>

                <div class="mt-6 p-4 border border-base-300 rounded-lg bg-base-200/60">
                  <p class="text-sm opacity-80">
                    These links are also available from Account Settings. Continuing will not change any setting automatically.
                  </p>
                </div>
              </div>
            <% 4 -> %>
              <div class="text-center">
                <div class="w-20 h-20 mx-auto bg-success/10 border-2 border-success/20 rounded-2xl flex items-center justify-center mb-6">
                  <.icon name="hero-check-circle" class="w-12 h-12 text-success" />
                </div>
                <h2 class="text-3xl font-bold mb-3">Pick a starting point</h2>
                <p class="text-lg opacity-70 mb-8">
                  Finish onboarding, then open whichever tool you actually need first.
                </p>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-8">
                  <.link
                    navigate={Elektrine.Paths.chat_root_path()}
                    class="card panel-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon
                        name="hero-chat-bubble-left-right"
                        class="w-8 h-8 mx-auto mb-2 text-primary"
                      />
                      <h3 class="font-bold">Arblarg</h3>
                      <p class="text-sm opacity-70">Direct and group messages</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/discussions"}
                    class="card panel-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-users" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Communities</h3>
                      <p class="text-sm opacity-70">Discussions and moderation</p>
                    </div>
                  </.link>

                  <.link
                    navigate={Elektrine.Paths.timeline_path()}
                    class="card panel-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-newspaper" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Timeline</h3>
                      <p class="text-sm opacity-70">Short posts and follows</p>
                    </div>
                  </.link>

                  <.link
                    navigate={Elektrine.Paths.email_index_path()}
                    class="card panel-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-envelope" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Email</h3>
                      <p class="text-sm opacity-70">Inbox, aliases, and clients</p>
                    </div>
                  </.link>

                  <.link
                    navigate={Elektrine.Paths.vpn_path()}
                    class="card panel-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-shield-check" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">VPN</h3>
                      <p class="text-sm opacity-70">WireGuard configuration</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/#{@current_user.handle || @current_user.username}"}
                    class="card panel-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-user-circle" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">View Profile</h3>
                      <p class="text-sm opacity-70">Public profile page</p>
                    </div>
                  </.link>
                </div>

                <div class="alert alert-info">
                  <.icon name="hero-information-circle" class="w-5 h-5" />
                  <div class="text-left">
                    <p class="font-medium">
                      You can change this later
                    </p>
                    <p class="text-xs opacity-70">
                      Account Settings includes profile, security, privacy, notification, and email controls.
                    </p>
                  </div>
                </div>
              </div>
            <% _ -> %>
              <p>Unknown step</p>
          <% end %>

          <div class="flex justify-between items-center mt-8 pt-6 border-t border-base-300">
            <div>
              <%= if @step > 1 do %>
                <button phx-click="prev_step" class="btn btn-ghost">
                  <.icon name="hero-arrow-left" class="w-4 h-4 mr-1" /> Back
                </button>
              <% else %>
                <button phx-click="skip_onboarding" class="btn btn-ghost">
                  Skip Setup
                </button>
              <% end %>
            </div>

            <div>
              <%= if @step < @total_steps do %>
                <%= if @step == 2 do %>
                  <button
                    phx-click="save_profile"
                    class="btn btn-primary"
                  >
                    Continue <.icon name="hero-arrow-right" class="w-4 h-4 ml-1" />
                  </button>
                <% else %>
                  <button phx-click="next_step" class="btn btn-primary">
                    Continue <.icon name="hero-arrow-right" class="w-4 h-4 ml-1" />
                  </button>
                <% end %>
              <% else %>
                <button phx-click="complete_onboarding" class="btn btn-primary">
                  <.icon name="hero-check" class="w-4 h-4 mr-1" /> Finish Setup
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
