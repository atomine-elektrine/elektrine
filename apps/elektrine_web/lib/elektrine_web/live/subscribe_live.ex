defmodule ElektrineWeb.SubscribeLive do
  @moduledoc """
  Universal subscription page for products.
  Handles checkout and subscription management via Stripe.
  Products and prices are managed via admin panel.
  """
  use ElektrineWeb, :live_view

  alias Elektrine.Subscriptions
  alias Elektrine.Subscriptions.{Product, Subscription}

  import ElektrineWeb.Components.Platform.ElektrineNav

  @impl true
  def mount(%{"product" => product_slug}, _session, socket) do
    user = socket.assigns[:current_user]
    product = Subscriptions.get_active_product_by_slug(product_slug)

    if product == nil do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      subscription = if user, do: Subscriptions.get_subscription(user.id, product_slug), else: nil

      socket =
        socket
        |> assign(:page_title, "Subscribe to #{product.name}")
        |> assign(:product, product)
        |> assign(:subscription, subscription)
        |> assign(:loading, false)
        |> assign(:error, nil)

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"success" => "true"}, _uri, socket) do
    # Refresh subscription status after successful checkout
    user = socket.assigns[:current_user]
    product = socket.assigns.product

    subscription = if user, do: Subscriptions.get_subscription(user.id, product.slug), else: nil

    socket =
      socket
      |> assign(:subscription, subscription)
      |> put_flash(:info, "Subscription activated successfully!")

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("checkout", %{"plan" => plan}, socket) do
    user = socket.assigns[:current_user]
    product = socket.assigns.product

    if user == nil do
      {:noreply, redirect(socket, to: ~p"/login")}
    else
      price_id =
        case plan do
          "monthly" -> product.stripe_monthly_price_id
          "yearly" -> product.stripe_yearly_price_id
          _ -> nil
        end

      if price_id && price_id != "" do
        socket = assign(socket, :loading, true)

        case Subscriptions.create_checkout_session(user, product.slug, price_id,
               success_url:
                 "#{ElektrineWeb.Endpoint.url()}/subscribe/#{product.slug}?success=true",
               cancel_url: "#{ElektrineWeb.Endpoint.url()}/subscribe/#{product.slug}"
             ) do
          {:ok, %{url: checkout_url}} ->
            {:noreply, redirect(socket, external: checkout_url)}

          {:error, error} ->
            {:noreply,
             socket
             |> assign(:loading, false)
             |> assign(:error, "Failed to create checkout session: #{inspect(error)}")}
        end
      else
        {:noreply, assign(socket, :error, "Price not configured. Please contact support.")}
      end
    end
  end

  def handle_event("manage", _params, socket) do
    user = socket.assigns[:current_user]
    product = socket.assigns.product

    if user do
      socket = assign(socket, :loading, true)

      case Subscriptions.create_portal_session(user, product.slug,
             return_url: "#{ElektrineWeb.Endpoint.url()}/subscribe/#{product.slug}"
           ) do
        {:ok, %{url: portal_url}} ->
          {:noreply, redirect(socket, external: portal_url)}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:loading, false)
           |> assign(:error, "Failed to open billing portal")}
      end
    else
      {:noreply, redirect(socket, to: ~p"/login")}
    end
  end

  def handle_event("cancel", _params, socket) do
    subscription = socket.assigns.subscription

    if subscription do
      case Subscriptions.cancel_subscription(subscription) do
        {:ok, updated_sub} ->
          {:noreply,
           socket
           |> assign(:subscription, updated_sub)
           |> put_flash(:info, "Subscription will be canceled at the end of the billing period.")}

        {:error, _} ->
          {:noreply, assign(socket, :error, "Failed to cancel subscription")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume", _params, socket) do
    subscription = socket.assigns.subscription

    if subscription do
      case Subscriptions.resume_subscription(subscription) do
        {:ok, updated_sub} ->
          {:noreply,
           socket
           |> assign(:subscription, updated_sub)
           |> put_flash(:info, "Subscription resumed!")}

        {:error, _} ->
          {:noreply, assign(socket, :error, "Failed to resume subscription")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl px-4 sm:px-6 lg:px-8 pb-8">
      <.elektrine_nav active_tab={@product.slug} />

      <div class="text-center mb-12">
        <h1 class="text-4xl font-bold text-base-content mb-4">
          {@product.name}
        </h1>
        <%= if @product.description do %>
          <p class="text-lg text-base-content/70 max-w-2xl mx-auto">
            {@product.description}
          </p>
        <% end %>
      </div>

      <%= if @error do %>
        <div class="alert alert-error mb-6">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error}</span>
        </div>
      <% end %>

      <%= if @subscription && Subscription.has_access?(@subscription) do %>
        <.subscription_active subscription={@subscription} product={@product} loading={@loading} />
      <% else %>
        <.pricing_cards
          product={@product}
          loading={@loading}
          current_user={@current_user}
        />
      <% end %>
    </div>
    """
  end

  defp subscription_active(assigns) do
    ~H"""
    <div class="card glass-card shadow-lg border border-base-300 max-w-lg mx-auto">
      <div class="card-body text-center">
        <div class="w-16 h-16 rounded-full bg-success/20 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-check-circle" class="w-8 h-8 text-success" />
        </div>

        <h2 class="text-2xl font-bold text-base-content mb-2">Subscription Active</h2>

        <p class="text-base-content/70 mb-4">
          You have full access to {@product.name}.
        </p>

        <div class="stats stats-vertical bg-base-200 rounded-box mb-6">
          <div class="stat">
            <div class="stat-title">Status</div>
            <div class="stat-value text-lg capitalize">{@subscription.status}</div>
          </div>

          <%= if @subscription.current_period_end do %>
            <div class="stat">
              <div class="stat-title">
                {if @subscription.cancel_at_period_end, do: "Access Until", else: "Renews On"}
              </div>
              <div class="stat-value text-lg">
                {Calendar.strftime(@subscription.current_period_end, "%B %d, %Y")}
              </div>
            </div>
          <% end %>
        </div>

        <%= if @subscription.cancel_at_period_end do %>
          <div class="alert alert-warning mb-4">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              Your subscription will end on {Calendar.strftime(
                @subscription.current_period_end,
                "%B %d, %Y"
              )}
            </span>
          </div>
          <button phx-click="resume" class="btn btn-primary btn-block" disabled={@loading}>
            {if @loading, do: "Loading...", else: "Resume Subscription"}
          </button>
        <% else %>
          <div class="space-y-2">
            <button phx-click="manage" class="btn btn-primary btn-block" disabled={@loading}>
              {if @loading, do: "Loading...", else: "Manage Subscription"}
            </button>
            <button
              phx-click="cancel"
              data-confirm="Are you sure you want to cancel? You'll keep access until the end of your billing period."
              class="btn btn-ghost btn-block text-error"
              disabled={@loading}
            >
              Cancel Subscription
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp pricing_cards(assigns) do
    assigns =
      assigns
      |> assign(:has_monthly, Product.has_monthly?(assigns.product))
      |> assign(:has_yearly, Product.has_yearly?(assigns.product))
      |> assign(
        :monthly_price,
        format_price(assigns.product.monthly_price_cents, assigns.product.currency)
      )
      |> assign(
        :yearly_price,
        format_price(assigns.product.yearly_price_cents, assigns.product.currency)
      )
      |> assign(
        :monthly_equivalent,
        calculate_monthly_equivalent(assigns.product.yearly_price_cents, assigns.product.currency)
      )
      |> assign(
        :savings_percent,
        calculate_savings(assigns.product.monthly_price_cents, assigns.product.yearly_price_cents)
      )

    ~H"""
    <div class="grid md:grid-cols-2 gap-6 max-w-3xl mx-auto">
      <!-- Monthly Plan -->
      <div class="card glass-card shadow-lg border border-base-300 hover:border-secondary/50 transition-colors">
        <div class="card-body">
          <h3 class="text-xl font-semibold text-base-content">Monthly</h3>
          <div class="my-4">
            <%= if @monthly_price do %>
              <span class="text-4xl font-bold text-base-content">{@monthly_price}</span>
              <span class="text-base-content/60">/month</span>
            <% else %>
              <span class="text-2xl text-base-content/50">Price not set</span>
            <% end %>
          </div>
          <ul class="space-y-2 mb-6">
            <%= for feature <- @product.features || [] do %>
              <li class="flex items-start gap-2">
                <.icon name="hero-check" class="w-5 h-5 text-success flex-shrink-0 mt-0.5" />
                <span class="text-base-content/80">{feature}</span>
              </li>
            <% end %>
          </ul>
          <%= if @current_user do %>
            <%= if @has_monthly do %>
              <button
                phx-click="checkout"
                phx-value-plan="monthly"
                class="btn btn-secondary btn-block"
                disabled={@loading}
              >
                {if @loading, do: "Loading...", else: "Subscribe Monthly"}
              </button>
            <% else %>
              <button class="btn btn-disabled btn-block">Coming Soon</button>
            <% end %>
          <% else %>
            <.link href={~p"/login"} class="btn btn-secondary btn-block">
              Log in to Subscribe
            </.link>
          <% end %>
        </div>
      </div>
      
    <!-- Yearly Plan -->
      <div class="card glass-card shadow-lg border-2 border-secondary relative">
        <%= if @savings_percent && @savings_percent > 0 do %>
          <div class="absolute -top-3 left-1/2 -translate-x-1/2">
            <span class="badge badge-secondary">Save {@savings_percent}%</span>
          </div>
        <% end %>
        <div class="card-body">
          <h3 class="text-xl font-semibold text-base-content">Yearly</h3>
          <div class="my-4">
            <%= if @yearly_price do %>
              <span class="text-4xl font-bold text-base-content">{@yearly_price}</span>
              <span class="text-base-content/60">/year</span>
              <%= if @monthly_equivalent do %>
                <div class="text-sm text-base-content/50">{@monthly_equivalent}/month</div>
              <% end %>
            <% else %>
              <span class="text-2xl text-base-content/50">Price not set</span>
            <% end %>
          </div>
          <ul class="space-y-2 mb-6">
            <%= for feature <- @product.features || [] do %>
              <li class="flex items-start gap-2">
                <.icon name="hero-check" class="w-5 h-5 text-success flex-shrink-0 mt-0.5" />
                <span class="text-base-content/80">{feature}</span>
              </li>
            <% end %>
          </ul>
          <%= if @current_user do %>
            <%= if @has_yearly do %>
              <button
                phx-click="checkout"
                phx-value-plan="yearly"
                class="btn btn-primary btn-block"
                disabled={@loading}
              >
                {if @loading, do: "Loading...", else: "Subscribe Yearly"}
              </button>
            <% else %>
              <button class="btn btn-disabled btn-block">Coming Soon</button>
            <% end %>
          <% else %>
            <.link href={~p"/login"} class="btn btn-primary btn-block">
              Log in to Subscribe
            </.link>
          <% end %>
        </div>
      </div>
    </div>

    <div class="text-center mt-8 text-base-content/60 text-sm">
      <p>Secure payment powered by Stripe. Cancel anytime.</p>
    </div>
    """
  end

  defp format_price(nil, _currency), do: nil

  defp format_price(cents, currency) when is_integer(cents) do
    Product.format_price(cents, currency)
  end

  defp calculate_monthly_equivalent(nil, _currency), do: nil

  defp calculate_monthly_equivalent(yearly_cents, currency) when is_integer(yearly_cents) do
    monthly_cents = div(yearly_cents, 12)
    Product.format_price(monthly_cents, currency)
  end

  defp calculate_savings(nil, _yearly), do: nil
  defp calculate_savings(_monthly, nil), do: nil

  defp calculate_savings(monthly_cents, yearly_cents) when monthly_cents > 0 do
    full_year_at_monthly = monthly_cents * 12
    savings = (full_year_at_monthly - yearly_cents) / full_year_at_monthly * 100
    round(savings)
  end

  defp calculate_savings(_, _), do: nil
end
