defmodule ElektrineWeb.OnboardingLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Profiles

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Redirect if already completed onboarding
    if user.onboarding_completed do
      {:ok, push_navigate(socket, to: ~p"/chat")}
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
    # Use values from socket assigns (updated via phx-keyup)
    bio = socket.assigns.bio
    handle = String.trim(socket.assigns.handle || "")

    # Always update handle if it has a value (even if not "changed" by user)
    result =
      if handle != "" && handle != socket.assigns.current_user.handle do
        socket.assigns.current_user
        |> Elektrine.Accounts.User.handle_changeset(%{handle: handle})
        |> Elektrine.Repo.update()
      else
        {:ok, socket.assigns.current_user}
      end

    case result do
      {:ok, updated_user} ->
        # Reload user to get fresh handle for navbar
        fresh_user = Elektrine.Repo.get!(Elektrine.Accounts.User, updated_user.id)

        # Update user profile description (the field is called description, not bio)
        bio_result =
          if bio != "" do
            Profiles.upsert_user_profile(fresh_user.id, %{description: bio})
          else
            # Skip if bio is empty
            {:ok, nil}
          end

        case bio_result do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:current_user, fresh_user)
             |> put_flash(:info, "Profile saved!")
             |> assign(:step, 3)}

          {:error, _} ->
            # Handle and user updated, but bio failed - still proceed
            {:noreply,
             socket
             |> assign(:current_user, fresh_user)
             |> put_flash(:info, "Profile saved!")
             |> assign(:step, 3)}
        end

      {:error, changeset} ->
        errors = changeset.errors

        error_msg =
          case Keyword.get(errors, :handle) do
            {msg, _} -> msg
            _ -> "Invalid handle"
          end

        {:noreply, assign(socket, :handle_error, error_msg)}
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
     |> put_flash(:info, "Setup complete!")
     |> push_navigate(to: ~p"/chat")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl px-2 sm:px-4 lg:px-8 pb-8">
      <div class="card glass-card shadow-lg border border-base-300 mt-6">
        <div class="card-body p-6 sm:p-8">
          <!-- Progress Bar -->
          <div class="mb-8">
            <div class="flex justify-between mb-2">
              <span class="text-sm font-medium">Step {@step} of {@total_steps}</span>
              <span class="text-sm opacity-70">{round(@step / @total_steps * 100)}% complete</span>
            </div>
            <progress class="progress progress-primary w-full" value={@step} max={@total_steps}>
            </progress>
          </div>
          
    <!-- Step Content -->
          <%= case @step do %>
            <% 1 -> %>
              <!-- Welcome Step -->
              <div class="text-center">
                <div class="mb-6">
                  <div class="w-20 h-20 mx-auto bg-primary/10 rounded-2xl flex items-center justify-center mb-4 border-2 border-primary/20">
                    <.icon name="hero-sparkles" class="w-12 h-12 text-primary" />
                  </div>
                  <h1 class="text-3xl font-bold mb-3">Welcome!</h1>
                  <p class="text-lg opacity-70">Let's get you set up</p>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-left my-8">
                  <div class="flex gap-3 p-4 bg-base-200 border border-base-300 rounded-lg">
                    <.icon
                      name="hero-chat-bubble-left-right"
                      class="w-6 h-6 text-primary flex-shrink-0 mt-1"
                    />
                    <div>
                      <h3 class="font-semibold mb-1">Chat</h3>
                      <p class="text-sm opacity-70">Real-time messaging with friends and groups</p>
                    </div>
                  </div>
                  <div class="flex gap-3 p-4 bg-base-200 border border-base-300 rounded-lg">
                    <.icon name="hero-envelope" class="w-6 h-6 text-primary flex-shrink-0 mt-1" />
                    <div>
                      <h3 class="font-semibold mb-1">Email</h3>
                      <p class="text-sm opacity-70">Full email client with IMAP, POP3, and SMTP</p>
                    </div>
                  </div>
                  <div class="flex gap-3 p-4 bg-base-200 border border-base-300 rounded-lg">
                    <.icon name="hero-users" class="w-6 h-6 text-primary flex-shrink-0 mt-1" />
                    <div>
                      <h3 class="font-semibold mb-1">Discussions</h3>
                      <p class="text-sm opacity-70">
                        Deep conversations with voting, threads, and moderation
                      </p>
                    </div>
                  </div>
                  <div class="flex gap-3 p-4 bg-base-200 border border-base-300 rounded-lg">
                    <.icon name="hero-newspaper" class="w-6 h-6 text-primary flex-shrink-0 mt-1" />
                    <div>
                      <h3 class="font-semibold mb-1">Timeline</h3>
                      <p class="text-sm opacity-70">Quick updates and posts</p>
                    </div>
                  </div>
                  <div class="flex gap-3 p-4 bg-base-200 border border-base-300 rounded-lg">
                    <.icon name="hero-user-circle" class="w-6 h-6 text-primary flex-shrink-0 mt-1" />
                    <div>
                      <h3 class="font-semibold mb-1">Profile</h3>
                      <p class="text-sm opacity-70">Your customizable page</p>
                    </div>
                  </div>
                  <div class="flex gap-3 p-4 bg-base-200 border border-base-300 rounded-lg">
                    <.icon name="hero-shield-check" class="w-6 h-6 text-primary flex-shrink-0 mt-1" />
                    <div>
                      <h3 class="font-semibold mb-1">VPN</h3>
                      <p class="text-sm opacity-70">Secure your connection with WireGuard</p>
                    </div>
                  </div>
                </div>

                <p class="text-sm opacity-60 mb-6">
                  Let's get you set up in just a few quick steps
                </p>
              </div>
            <% 2 -> %>
              <!-- Profile Setup Step -->
              <div>
                <h2 class="text-2xl font-bold mb-3 text-center">Set Up Your Profile</h2>
                <p class="text-center opacity-70 mb-8">
                  Tell us a bit about yourself (you can always change this later)
                </p>

                <div class="space-y-6">
                  <div class="flex flex-col items-center mb-6">
                    <div class="w-24 h-24 bg-primary/10 border-2 border-primary/20 rounded-full flex items-center justify-center text-primary text-3xl font-bold mb-3">
                      {String.first(String.upcase(@current_user.username))}
                    </div>
                    <p class="text-sm opacity-70">Upload avatar in Account Settings later</p>
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
                        Your email address ({@current_user.username}@elektrine.com) and login credential
                      </span>
                    </label>
                  </div>

                  <div class="form-control w-full">
                    <label class="label">
                      <span class="label-text font-medium">Handle</span>
                    </label>
                    <input
                      type="text"
                      name="handle"
                      value={@handle}
                      placeholder={@current_user.username}
                      class={"input input-bordered w-full #{if @handle_error, do: "input-error"}"}
                      phx-keyup="update_handle"
                      phx-debounce="300"
                      maxlength="20"
                    />
                    <%= if @handle_error do %>
                      <label class="label">
                        <span class="label-text-alt text-error">{@handle_error}</span>
                      </label>
                    <% else %>
                      <label class="label">
                        <span class="label-text-alt">
                          Your public handle will be @{@handle || @current_user.username} - what others see
                        </span>
                      </label>
                    <% end %>
                    <%= if !@handle_changed do %>
                      <div class="alert alert-warning mt-2">
                        <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                        <div class="text-sm">
                          <p class="font-medium mb-1">Username vs Handle:</p>
                          <p>• Username = Email address and login</p>
                          <p>• Handle = What others see and mention</p>
                          <p class="mt-2">
                            Customize your handle now or it will default to your username
                          </p>
                        </div>
                      </div>
                    <% end %>
                  </div>

                  <div class="form-control w-full">
                    <label class="label">
                      <span class="label-text font-medium">Bio (Optional)</span>
                    </label>
                    <textarea
                      placeholder="Tell others about yourself..."
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
                </div>
              </div>
            <% 3 -> %>
              <!-- Platform Tour Step -->
              <div>
                <h2 class="text-2xl font-bold mb-3 text-center">Explore the Platform</h2>
                <p class="text-center opacity-70 mb-8">Here's what you can do on Elektrine</p>

                <div class="space-y-4">
                  <div class="card bg-base-200 border border-base-300 shadow-sm">
                    <div class="card-body p-6">
                      <div class="flex items-start gap-4">
                        <div class="w-12 h-12 bg-primary/10 border border-primary/20 rounded-lg flex items-center justify-center flex-shrink-0">
                          <.icon name="hero-chat-bubble-left-right" class="w-6 h-6 text-primary" />
                        </div>
                        <div class="flex-1">
                          <h3 class="font-bold text-lg mb-2">Chat & Messaging</h3>
                          <p class="text-sm opacity-70 mb-3">
                            Send messages, create group chats, and stay connected with friends. Real-time communication for work and personal use.
                          </p>
                          <.link navigate={~p"/chat"} class="btn btn-sm btn-primary">
                            <.icon name="hero-arrow-right" class="w-4 h-4 mr-1" /> Go to Chat
                          </.link>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="card bg-base-200 border border-base-300 shadow-sm">
                    <div class="card-body p-6">
                      <div class="flex items-start gap-4">
                        <div class="w-12 h-12 bg-primary/10 border border-primary/20 rounded-lg flex items-center justify-center flex-shrink-0">
                          <.icon name="hero-envelope" class="w-6 h-6 text-primary" />
                        </div>
                        <div class="flex-1">
                          <h3 class="font-bold text-lg mb-2">Email</h3>
                          <p class="text-sm opacity-70 mb-3">
                            Your personal email address (@elektrine.com and @z.org). Access via web, IMAP, POP3, or SMTP. Full email client with folders, search, and attachments.
                          </p>
                          <.link navigate={~p"/email"} class="btn btn-sm btn-primary">
                            <.icon name="hero-arrow-right" class="w-4 h-4 mr-1" /> Go to Email
                          </.link>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="card bg-base-200 border border-base-300 shadow-sm">
                    <div class="card-body p-6">
                      <div class="flex items-start gap-4">
                        <div class="w-12 h-12 bg-primary/10 border border-primary/20 rounded-lg flex items-center justify-center flex-shrink-0">
                          <.icon name="hero-users" class="w-6 h-6 text-primary" />
                        </div>
                        <div class="flex-1">
                          <h3 class="font-bold text-lg mb-2">Discussions</h3>
                          <p class="text-sm opacity-70 mb-3">
                            Join communities for in-depth conversations. Create discussion posts with titles, vote on content, and engage in threaded debates on topics you care about.
                          </p>
                          <.link navigate={~p"/discussions"} class="btn btn-sm btn-primary">
                            <.icon name="hero-arrow-right" class="w-4 h-4 mr-1" /> Browse Communities
                          </.link>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="card bg-base-200 border border-base-300 shadow-sm">
                    <div class="card-body p-6">
                      <div class="flex items-start gap-4">
                        <div class="w-12 h-12 bg-primary/10 border border-primary/20 rounded-lg flex items-center justify-center flex-shrink-0">
                          <.icon name="hero-newspaper" class="w-6 h-6 text-primary" />
                        </div>
                        <div class="flex-1">
                          <h3 class="font-bold text-lg mb-2">Timeline</h3>
                          <p class="text-sm opacity-70 mb-3">
                            Share quick updates, thoughts, and photos. Short and casual posts to keep your followers updated. Follow others and build your social network.
                          </p>
                          <.link navigate={~p"/timeline"} class="btn btn-sm btn-primary">
                            <.icon name="hero-arrow-right" class="w-4 h-4 mr-1" /> View Timeline
                          </.link>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="card bg-base-200 border border-base-300 shadow-sm">
                    <div class="card-body p-6">
                      <div class="flex items-start gap-4">
                        <div class="w-12 h-12 bg-primary/10 border border-primary/20 rounded-lg flex items-center justify-center flex-shrink-0">
                          <.icon name="hero-shield-check" class="w-6 h-6 text-primary" />
                        </div>
                        <div class="flex-1">
                          <h3 class="font-bold text-lg mb-2">VPN</h3>
                          <p class="text-sm opacity-70 mb-3">
                            Secure your internet connection with WireGuard VPN. Create configs for any device and protect your privacy. Trust Level based access to premium servers.
                          </p>
                          <.link navigate={~p"/vpn"} class="btn btn-sm btn-primary">
                            <.icon name="hero-arrow-right" class="w-4 h-4 mr-1" /> Set Up VPN
                          </.link>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% 4 -> %>
              <!-- Get Started Step -->
              <div class="text-center">
                <div class="w-20 h-20 mx-auto bg-success/10 border-2 border-success/20 rounded-2xl flex items-center justify-center mb-6">
                  <.icon name="hero-check-circle" class="w-12 h-12 text-success" />
                </div>
                <h2 class="text-3xl font-bold mb-3">You're All Set!</h2>
                <p class="text-lg opacity-70 mb-8">Ready to start using Elektrine?</p>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-8">
                  <.link
                    navigate={~p"/chat"}
                    class="card glass-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon
                        name="hero-chat-bubble-left-right"
                        class="w-8 h-8 mx-auto mb-2 text-primary"
                      />
                      <h3 class="font-bold">Start Chatting</h3>
                      <p class="text-sm opacity-70">Message your friends</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/discussions"}
                    class="card glass-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-users" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Join Communities</h3>
                      <p class="text-sm opacity-70">Find your interests</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/timeline"}
                    class="card glass-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-newspaper" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Share Updates</h3>
                      <p class="text-sm opacity-70">Post to your timeline</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/email"}
                    class="card glass-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-envelope" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Check Email</h3>
                      <p class="text-sm opacity-70">Manage your inbox</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/vpn"}
                    class="card glass-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-shield-check" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">Set Up VPN</h3>
                      <p class="text-sm opacity-70">Secure your connection</p>
                    </div>
                  </.link>

                  <.link
                    navigate={~p"/#{@current_user.handle || @current_user.username}"}
                    class="card glass-card border-2 border-base-300 hover:border-primary/40 hover:shadow-lg transition-all"
                  >
                    <div class="card-body p-6 text-center">
                      <.icon name="hero-user-circle" class="w-8 h-8 mx-auto mb-2 text-primary" />
                      <h3 class="font-bold">View Profile</h3>
                      <p class="text-sm opacity-70">Your personal page</p>
                    </div>
                  </.link>
                </div>

                <div class="alert alert-info">
                  <.icon name="hero-information-circle" class="w-5 h-5" />
                  <div class="text-left">
                    <p class="font-medium">
                      Tip: Visit Account Settings to customize your experience
                    </p>
                    <p class="text-xs opacity-70">
                      Set your avatar, adjust preferences, and configure notifications
                    </p>
                  </div>
                </div>
              </div>
            <% _ -> %>
              <p>Unknown step</p>
          <% end %>
          
    <!-- Navigation Buttons -->
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
                  <.icon name="hero-check" class="w-4 h-4 mr-1" /> Get Started
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
