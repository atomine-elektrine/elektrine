defmodule Elektrine.Subscriptions do
  @moduledoc """
  Context for managing user subscriptions.

  This is a universal subscription system that can be used for any product.
  Products and prices are managed via the admin panel.
  Integrates with Stripe for payment processing.
  """
  import Ecto.Query
  require Logger
  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Subscriptions.{Product, Subscription}

  # ===========================================================================
  # Product Management
  # ===========================================================================

  @doc """
  List all subscription products.
  """
  def list_products do
    from(p in Product, order_by: [asc: p.sort_order, asc: p.name])
    |> Repo.all()
  end

  @doc """
  List active subscription products.
  """
  def list_active_products do
    from(p in Product, where: p.active == true, order_by: [asc: p.sort_order, asc: p.name])
    |> Repo.all()
  end

  @doc """
  Get a product by ID.
  """
  def get_product(id), do: Repo.get(Product, id)

  @doc """
  Get a product by slug.
  """
  def get_product_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Product, slug: slug)
  end

  @doc """
  Get an active product by slug.
  """
  def get_active_product_by_slug(slug) when is_binary(slug) do
    from(p in Product, where: p.slug == ^slug and p.active == true)
    |> Repo.one()
  end

  @doc """
  Create a new subscription product.
  """
  def create_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a subscription product.
  """
  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a subscription product.
  """
  def delete_product(%Product{} = product) do
    Repo.delete(product)
  end

  @doc """
  Get a product changeset for forms.
  """
  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  # ===========================================================================
  # Subscription Management
  # ===========================================================================

  @doc """
  Get a user's subscription for a specific product.
  """
  def get_subscription(user_id, product) when is_integer(user_id) and is_binary(product) do
    Repo.get_by(Subscription, user_id: user_id, product: product)
  end

  def get_subscription(%User{id: user_id}, product), do: get_subscription(user_id, product)

  @doc """
  Get subscription by Stripe subscription ID.
  """
  def get_subscription_by_stripe_id(stripe_subscription_id) do
    Repo.get_by(Subscription, stripe_subscription_id: stripe_subscription_id)
  end

  @doc """
  Get subscription by Stripe customer ID and product.
  """
  def get_subscription_by_customer(stripe_customer_id, product) do
    Repo.get_by(Subscription, stripe_customer_id: stripe_customer_id, product: product)
  end

  @doc """
  Check if a user has access to a product.
  Admins always have access. Otherwise checks for active subscription.
  """
  def has_access?(nil, _product), do: false

  def has_access?(%User{is_admin: true}, _product), do: true

  def has_access?(%User{id: user_id}, product) do
    has_access?(user_id, product)
  end

  def has_access?(user_id, product) when is_integer(user_id) do
    case get_subscription(user_id, product) do
      %Subscription{} = sub -> Subscription.has_access?(sub)
      nil -> false
    end
  end

  @doc """
  Get or create a Stripe customer for a user.
  Returns {:ok, stripe_customer_id} or {:error, reason}.
  """
  def get_or_create_stripe_customer(%User{} = user, product) do
    case get_subscription(user.id, product) do
      %Subscription{stripe_customer_id: cid} when is_binary(cid) ->
        {:ok, cid}

      subscription ->
        create_stripe_customer(user, product, subscription)
    end
  end

  defp create_stripe_customer(user, product, existing_subscription) do
    customer_params = %{
      email: "#{user.username}@z.org",
      name: user.display_name || user.username,
      metadata: %{
        user_id: to_string(user.id),
        username: user.username
      }
    }

    case Stripe.Customer.create(customer_params) do
      {:ok, %{id: customer_id}} ->
        # Update or create subscription record with customer ID
        result =
          if existing_subscription do
            existing_subscription
            |> Subscription.customer_changeset(%{stripe_customer_id: customer_id})
            |> Repo.update()
          else
            %Subscription{}
            |> Subscription.create_changeset(%{
              user_id: user.id,
              product: product,
              stripe_customer_id: customer_id
            })
            |> Repo.insert()
          end

        case result do
          {:ok, _} -> {:ok, customer_id}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Create a Stripe Checkout session for a product subscription.
  Returns {:ok, checkout_session} or {:error, reason}.
  """
  def create_checkout_session(%User{} = user, product, price_id, opts \\ []) do
    success_url = Keyword.get(opts, :success_url, "#{base_url()}/subscribe/#{product}/success")
    cancel_url = Keyword.get(opts, :cancel_url, "#{base_url()}/subscribe/#{product}")

    with {:ok, customer_id} <- get_or_create_stripe_customer(user, product) do
      session_params = %{
        customer: customer_id,
        mode: "subscription",
        line_items: [
          %{
            price: price_id,
            quantity: 1
          }
        ],
        success_url: success_url,
        cancel_url: cancel_url,
        subscription_data: %{
          metadata: %{
            user_id: to_string(user.id),
            product: product
          }
        },
        metadata: %{
          user_id: to_string(user.id),
          product: product
        }
      }

      Stripe.Checkout.Session.create(session_params)
    end
  end

  @doc """
  Create a Stripe Customer Portal session for managing subscriptions.
  Returns {:ok, portal_session} or {:error, reason}.
  """
  def create_portal_session(%User{} = user, product, opts \\ []) do
    return_url = Keyword.get(opts, :return_url, "#{base_url()}/subscribe/#{product}")

    case get_subscription(user.id, product) do
      %Subscription{stripe_customer_id: customer_id} when is_binary(customer_id) ->
        Stripe.BillingPortal.Session.create(%{
          customer: customer_id,
          return_url: return_url
        })

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Process a Stripe webhook event.
  """
  def process_webhook_event(%{type: type, data: data}) do
    case type do
      "customer.subscription.created" ->
        handle_subscription_created(data.object)

      "customer.subscription.updated" ->
        handle_subscription_updated(data.object)

      "customer.subscription.deleted" ->
        handle_subscription_deleted(data.object)

      "invoice.payment_succeeded" ->
        handle_payment_succeeded(data.object)

      "invoice.payment_failed" ->
        handle_payment_failed(data.object)

      _ ->
        # Ignore unhandled event types
        {:ok, :ignored}
    end
  end

  defp handle_subscription_created(stripe_sub) do
    price_id = get_price_id(stripe_sub)
    stripe_subscription_id = stripe_sub[:id] || stripe_sub["id"]

    product =
      get_in(stripe_sub, [:metadata, "product"]) || get_in(stripe_sub, ["metadata", "product"]) ||
        product_from_price_id(price_id)

    if !is_binary(product) or product == "" do
      Logger.warning(
        "Stripe webhook: missing/unknown product; ignoring event (stripe_subscription_id=#{inspect(stripe_subscription_id)}, price_id=#{inspect(price_id)})"
      )

      {:ok, :ignored}
    else
      create_or_update_subscription_from_stripe(product, stripe_sub, price_id)
    end
  end

  defp create_or_update_subscription_from_stripe(product, stripe_sub, price_id) do
    customer_id = stripe_sub[:customer] || stripe_sub["customer"]

    # Find existing subscription by customer ID or create new
    case get_subscription_by_customer(customer_id, product) do
      %Subscription{} = sub ->
        update_from_stripe(sub, stripe_sub)

      nil ->
        # Try to find user by metadata
        user_id =
          get_in(stripe_sub, [:metadata, "user_id"]) ||
            get_in(stripe_sub, ["metadata", "user_id"])

        if user_id do
          %Subscription{}
          |> Subscription.create_changeset(%{
            user_id: String.to_integer(to_string(user_id)),
            product: product,
            stripe_customer_id: customer_id,
            stripe_subscription_id: stripe_sub[:id] || stripe_sub["id"],
            stripe_price_id: price_id,
            status: stripe_sub[:status] || stripe_sub["status"],
            current_period_start:
              from_unix(stripe_sub[:current_period_start] || stripe_sub["current_period_start"]),
            current_period_end:
              from_unix(stripe_sub[:current_period_end] || stripe_sub["current_period_end"]),
            cancel_at_period_end:
              stripe_sub[:cancel_at_period_end] || stripe_sub["cancel_at_period_end"]
          })
          |> Repo.insert()
        else
          {:error, :no_user_id}
        end
    end
  end

  defp product_from_price_id(nil), do: nil

  defp product_from_price_id(price_id) when is_binary(price_id) do
    from(p in Product,
      where:
        p.stripe_monthly_price_id == ^price_id or
          p.stripe_yearly_price_id == ^price_id,
      select: p.slug
    )
    |> Repo.one()
  end

  defp handle_subscription_updated(stripe_sub) do
    sub_id = stripe_sub[:id] || stripe_sub["id"]

    case get_subscription_by_stripe_id(sub_id) do
      %Subscription{} = sub ->
        update_from_stripe(sub, stripe_sub)

      nil ->
        # Subscription not found, try to create it
        handle_subscription_created(stripe_sub)
    end
  end

  defp handle_subscription_deleted(stripe_sub) do
    sub_id = stripe_sub[:id] || stripe_sub["id"]

    case get_subscription_by_stripe_id(sub_id) do
      %Subscription{} = sub ->
        sub
        |> Subscription.webhook_changeset(%{
          status: "canceled",
          canceled_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

      nil ->
        {:ok, :not_found}
    end
  end

  defp handle_payment_succeeded(invoice) do
    subscription_id = invoice[:subscription] || invoice["subscription"]

    if subscription_id do
      case get_subscription_by_stripe_id(subscription_id) do
        %Subscription{} = sub ->
          # Update period dates if this is a renewal
          sub
          |> Subscription.webhook_changeset(%{
            status: "active",
            current_period_start: from_unix(invoice[:period_start] || invoice["period_start"]),
            current_period_end: from_unix(invoice[:period_end] || invoice["period_end"])
          })
          |> Repo.update()

        nil ->
          {:ok, :not_found}
      end
    else
      {:ok, :no_subscription}
    end
  end

  defp handle_payment_failed(invoice) do
    subscription_id = invoice[:subscription] || invoice["subscription"]

    if subscription_id do
      case get_subscription_by_stripe_id(subscription_id) do
        %Subscription{} = sub ->
          sub
          |> Subscription.webhook_changeset(%{status: "past_due"})
          |> Repo.update()

        nil ->
          {:ok, :not_found}
      end
    else
      {:ok, :no_subscription}
    end
  end

  defp update_from_stripe(subscription, stripe_sub) do
    subscription
    |> Subscription.webhook_changeset(%{
      stripe_subscription_id: stripe_sub[:id] || stripe_sub["id"],
      stripe_price_id: get_price_id(stripe_sub),
      status: stripe_sub[:status] || stripe_sub["status"],
      current_period_start:
        from_unix(stripe_sub[:current_period_start] || stripe_sub["current_period_start"]),
      current_period_end:
        from_unix(stripe_sub[:current_period_end] || stripe_sub["current_period_end"]),
      canceled_at: from_unix(stripe_sub[:canceled_at] || stripe_sub["canceled_at"]),
      cancel_at_period_end:
        stripe_sub[:cancel_at_period_end] || stripe_sub["cancel_at_period_end"]
    })
    |> Repo.update()
  end

  defp get_price_id(stripe_sub) do
    items = stripe_sub[:items] || stripe_sub["items"]
    data = items[:data] || items["data"] || []

    case data do
      [item | _] ->
        price = item[:price] || item["price"]
        price[:id] || price["id"]

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp from_unix(nil), do: nil

  defp from_unix(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp) |> DateTime.truncate(:second)
  end

  defp base_url do
    ElektrineWeb.Endpoint.url()
  end

  @doc """
  List all subscriptions for a user.
  """
  def list_user_subscriptions(user_id) when is_integer(user_id) do
    from(s in Subscription, where: s.user_id == ^user_id, order_by: [desc: s.inserted_at])
    |> Repo.all()
  end

  def list_user_subscriptions(%User{id: user_id}), do: list_user_subscriptions(user_id)

  @doc """
  Get price IDs for a product from database.
  Returns {monthly_price_id, yearly_price_id}.
  """
  def get_price_ids(product_slug) when is_binary(product_slug) do
    case get_product_by_slug(product_slug) do
      %Product{stripe_monthly_price_id: monthly, stripe_yearly_price_id: yearly} ->
        {monthly, yearly}

      nil ->
        {nil, nil}
    end
  end

  def get_price_ids(%Product{} = product) do
    {product.stripe_monthly_price_id, product.stripe_yearly_price_id}
  end

  @doc """
  Cancel a subscription at period end.
  """
  def cancel_subscription(%Subscription{stripe_subscription_id: sub_id} = subscription)
      when is_binary(sub_id) do
    case Stripe.Subscription.update(sub_id, %{cancel_at_period_end: true}) do
      {:ok, stripe_sub} ->
        update_from_stripe(subscription, stripe_sub)

      {:error, error} ->
        {:error, error}
    end
  end

  def cancel_subscription(_), do: {:error, :no_stripe_subscription}

  @doc """
  Resume a canceled subscription (if still in period).
  """
  def resume_subscription(%Subscription{stripe_subscription_id: sub_id} = subscription)
      when is_binary(sub_id) do
    case Stripe.Subscription.update(sub_id, %{cancel_at_period_end: false}) do
      {:ok, stripe_sub} ->
        update_from_stripe(subscription, stripe_sub)

      {:error, error} ->
        {:error, error}
    end
  end

  def resume_subscription(_), do: {:error, :no_stripe_subscription}
end
