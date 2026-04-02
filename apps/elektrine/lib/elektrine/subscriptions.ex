defmodule Elektrine.Subscriptions do
  @moduledoc """
  Context for managing user subscriptions.

  This is a universal subscription system that can be used for any product.
  Products and prices are managed via the admin panel.
  Integrates with Stripe for payment processing.
  """
  import Ecto.Query
  alias Ecto.Changeset
  require Logger
  alias Elektrine.Accounts.User
  alias Elektrine.EmailAddresses
  alias Elektrine.Repo
  alias Elektrine.Subscriptions.{Product, RegistrationCheckout, Subscription}

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
  Get the active one-time product used for paid registration.
  """
  def get_active_registration_product do
    case get_active_product_by_slug("registration") do
      %Product{} = product ->
        if Product.one_time?(product), do: product, else: nil

      _ ->
        nil
    end
  end

  @doc """
  Create a new subscription product.
  """
  def create_product(attrs) do
    attrs = normalize_product_attrs(attrs)

    case sync_product_pricing(%Product{}, attrs) do
      {:ok, synced_attrs} ->
        %Product{}
        |> Product.create_changeset(synced_attrs)
        |> Repo.insert()

      {:error, errors} ->
        {:error, product_changeset_with_errors(%Product{}, attrs, errors)}
    end
  end

  @doc """
  Update a subscription product.
  """
  def update_product(%Product{} = product, attrs) do
    attrs = normalize_product_attrs(attrs)

    case sync_product_pricing(product, attrs) do
      {:ok, synced_attrs} ->
        product
        |> Product.update_changeset(synced_attrs)
        |> Repo.update()

      {:error, errors} ->
        {:error, product_changeset_with_errors(product, attrs, errors)}
    end
  end

  @doc """
  Delete a subscription product.
  """
  def delete_product(%Product{} = product) do
    if product_has_subscriptions?(product) do
      {:error, :has_subscriptions}
    else
      Repo.delete(product)
    end
  end

  @doc """
  Get a product changeset for forms.
  """
  def change_product(%Product{} = product, attrs \\ %{}) do
    attrs = normalize_product_attrs(attrs)

    if product.id do
      Product.update_changeset(product, attrs)
    else
      Product.create_changeset(product, attrs)
    end
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
  def get_or_create_stripe_customer(%User{} = user, _product) do
    case user_stripe_customer_id(user) do
      cid when is_binary(cid) ->
        {:ok, cid}

      nil ->
        case existing_customer_id_for_user(user.id) do
          {:single, cid} ->
            case maybe_store_user_stripe_customer_id(user, cid) do
              {:ok, _user} -> {:ok, cid}
              {:error, reason} -> {:error, reason}
            end

          {:multiple, cid} ->
            Logger.warning(
              "Stripe billing: multiple customer records detected for user #{user.id}; reusing #{inspect(cid)}"
            )

            {:ok, cid}

          :none ->
            create_stripe_customer(user)
        end
    end
  end

  defp create_stripe_customer(user) do
    customer_params = %{
      email: billing_email_for(user),
      name: user.display_name || user.username,
      metadata: %{
        user_id: to_string(user.id),
        username: user.username
      }
    }

    case stripe_client().create_customer(customer_params) do
      {:ok, %{id: customer_id}} ->
        case maybe_store_user_stripe_customer_id(user, customer_id) do
          {:ok, _user} -> {:ok, customer_id}
          {:error, reason} -> {:error, reason}
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
    success_url =
      Keyword.get(opts, :success_url, "#{base_url()}/subscribe/#{product}?success=true")

    cancel_url = Keyword.get(opts, :cancel_url, "#{base_url()}/subscribe/#{product}")
    checkout_mode = normalize_checkout_mode(Keyword.get(opts, :checkout_mode, :subscription))
    metadata = checkout_metadata(user.id, product, price_id, checkout_mode)

    with {:ok, customer_id} <- get_or_create_stripe_customer(user, product) do
      session_params =
        %{
          customer: customer_id,
          mode: checkout_mode,
          line_items: [
            %{
              price: price_id,
              quantity: 1
            }
          ],
          success_url: success_url,
          cancel_url: cancel_url,
          client_reference_id: to_string(user.id),
          metadata: metadata
        }
        |> maybe_put_subscription_data(checkout_mode, metadata)
        |> maybe_put_payment_data(checkout_mode, metadata)

      stripe_client().create_checkout_session(session_params)
    end
  end

  @doc """
  Create a guest Stripe Checkout session for a paid registration invite.
  Returns {:ok, checkout_session} or {:error, reason}.
  """
  def create_registration_checkout_session(%Product{} = product, opts \\ []) do
    with true <- Product.one_time?(product),
         true <- Product.has_one_time?(product) do
      lookup_token = generate_lookup_token()

      success_url =
        Keyword.get(
          opts,
          :success_url,
          "#{base_url()}/register/purchase/success?checkout_session_id={CHECKOUT_SESSION_ID}&access=#{lookup_token}"
        )

      cancel_url = Keyword.get(opts, :cancel_url, "#{base_url()}/register")

      metadata =
        registration_checkout_metadata(
          product.slug,
          product.stripe_one_time_price_id,
          lookup_token
        )

      session_params =
        %{
          customer_creation: "always",
          mode: "payment",
          line_items: [
            %{
              price: product.stripe_one_time_price_id,
              quantity: 1
            }
          ],
          success_url: success_url,
          cancel_url: cancel_url,
          metadata: metadata
        }
        |> maybe_put_payment_data("payment", metadata)

      case stripe_client().create_checkout_session(session_params) do
        {:ok, session} ->
          case ensure_registration_checkout_record(product.slug, session, lookup_token) do
            {:ok, _checkout} -> {:ok, session}
            {:error, _reason} -> {:ok, session}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :product_not_available}
    end
  end

  @doc """
  Get a registration checkout by Stripe session ID and access token.
  """
  def get_registration_checkout(session_id, lookup_token)
      when is_binary(session_id) and is_binary(lookup_token) do
    from(c in RegistrationCheckout,
      where:
        c.stripe_checkout_session_id == ^String.trim(session_id) and
          c.lookup_token == ^String.trim(lookup_token)
    )
    |> Repo.one()
    |> case do
      %RegistrationCheckout{} = checkout -> Repo.preload(checkout, :invite_code)
      nil -> nil
    end
  end

  @doc """
  Get a registration checkout by access token.
  """
  def get_registration_checkout_by_token(lookup_token) when is_binary(lookup_token) do
    lookup_token = String.trim(lookup_token)

    if lookup_token == "" do
      nil
    else
      from(c in RegistrationCheckout, where: c.lookup_token == ^lookup_token)
      |> Repo.one()
      |> case do
        %RegistrationCheckout{} = checkout -> Repo.preload(checkout, :invite_code)
        nil -> nil
      end
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
        stripe_client().create_billing_portal_session(%{
          customer: customer_id,
          return_url: return_url
        })

      %Subscription{} ->
        case user_stripe_customer_id(user) do
          nil ->
            {:error, :no_subscription}

          customer_id ->
            stripe_client().create_billing_portal_session(%{
              customer: customer_id,
              return_url: return_url
            })
        end

      _ ->
        case user_stripe_customer_id(user) do
          nil ->
            {:error, :no_subscription}

          customer_id ->
            stripe_client().create_billing_portal_session(%{
              customer: customer_id,
              return_url: return_url
            })
        end
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

      "checkout.session.completed" ->
        handle_checkout_session_completed(data.object)

      "checkout.session.async_payment_succeeded" ->
        handle_checkout_session_completed(data.object)

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
    customer_id = stripe_field(stripe_sub, :customer)

    # Find existing subscription by customer ID or create new
    case get_subscription_by_customer(customer_id, product) do
      %Subscription{} = sub ->
        update_from_stripe(sub, stripe_sub)

      nil ->
        case resolve_webhook_user(customer_id, stripe_sub) do
          %User{} = user ->
            maybe_store_user_stripe_customer_id(user, customer_id)

            %Subscription{}
            |> Subscription.create_changeset(%{
              user_id: user.id,
              product: product,
              stripe_customer_id: customer_id,
              stripe_subscription_id: stripe_field(stripe_sub, :id),
              stripe_price_id: price_id,
              status: stripe_field(stripe_sub, :status),
              current_period_start: from_unix(stripe_field(stripe_sub, :current_period_start)),
              current_period_end: from_unix(stripe_field(stripe_sub, :current_period_end)),
              cancel_at_period_end: stripe_field(stripe_sub, :cancel_at_period_end)
            })
            |> Repo.insert()

          nil ->
            {:error, :no_user_id}
        end
    end
  end

  defp product_from_price_id(nil), do: nil

  defp product_from_price_id(price_id) when is_binary(price_id) do
    from(p in Product,
      where:
        p.stripe_monthly_price_id == ^price_id or
          p.stripe_yearly_price_id == ^price_id or
          p.stripe_one_time_price_id == ^price_id,
      select: p.slug
    )
    |> Repo.one()
  end

  defp handle_checkout_session_completed(session) do
    cond do
      stripe_field(session, :mode) != "payment" ->
        {:ok, :ignored}

      stripe_field(session, :payment_status) != "paid" ->
        {:ok, :ignored}

      registration_checkout_session?(session) ->
        fulfill_registration_checkout(session)

      true ->
        create_or_update_one_time_purchase_from_checkout(session)
    end
  end

  defp fulfill_registration_checkout(session) do
    price_id = metadata_value(session, :price_id)
    product_slug = metadata_value(session, :product) || product_from_price_id(price_id)

    with %Product{} = product <- get_product_by_slug(product_slug),
         true <- Product.one_time?(product),
         {:ok, %RegistrationCheckout{} = checkout} <-
           ensure_registration_checkout_record(product.slug, session) do
      Repo.transaction(fn ->
        checkout =
          from(c in RegistrationCheckout,
            where: c.id == ^checkout.id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()
          |> Repo.preload(:invite_code)

        case checkout.status do
          "fulfilled" ->
            checkout

          _ ->
            case

            checkout
            |> RegistrationCheckout.fulfill_changeset(%{
              stripe_customer_id: stripe_field(session, :customer),
              stripe_payment_intent_id: stripe_field(session, :payment_intent),
              customer_email: registration_customer_email(session),
              fulfilled_at:
                from_unix(stripe_field(session, :created)) ||
                  DateTime.utc_now() |> DateTime.truncate(:second),
              status: "fulfilled"
            })
            |> Repo.update do
              {:ok, updated_checkout} ->
                Repo.preload(updated_checkout, :invite_code)

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)
    else
      _ ->
        {:ok, :ignored}
    end
  end

  defp create_or_update_one_time_purchase_from_checkout(session) do
    customer_id = stripe_field(session, :customer)
    price_id = metadata_value(session, :price_id)
    product_slug = metadata_value(session, :product) || product_from_price_id(price_id)

    with %Product{} = product <- get_product_by_slug(product_slug),
         true <- Product.one_time?(product),
         %User{} = user <- resolve_webhook_user(customer_id, session) do
      maybe_store_user_stripe_customer_id(user, customer_id)

      attrs = %{
        user_id: user.id,
        product: product.slug,
        stripe_customer_id: customer_id,
        stripe_subscription_id: nil,
        stripe_price_id: price_id,
        status: "active",
        current_period_start:
          from_unix(stripe_field(session, :created)) ||
            DateTime.utc_now() |> DateTime.truncate(:second),
        current_period_end: nil,
        canceled_at: nil,
        cancel_at_period_end: false,
        metadata: one_time_checkout_metadata(session)
      }

      case get_subscription(user.id, product.slug) ||
             get_subscription_by_customer(customer_id, product.slug) do
        %Subscription{} = subscription ->
          subscription
          |> Subscription.webhook_changeset(Map.delete(attrs, :user_id))
          |> Repo.update()

        nil ->
          %Subscription{}
          |> Subscription.create_changeset(attrs)
          |> Repo.insert()
      end
    else
      _ ->
        {:ok, :ignored}
    end
  end

  defp handle_subscription_updated(stripe_sub) do
    sub_id = stripe_field(stripe_sub, :id)

    case get_subscription_by_stripe_id(sub_id) do
      %Subscription{} = sub ->
        update_from_stripe(sub, stripe_sub)

      nil ->
        # Subscription not found, try to create it
        handle_subscription_created(stripe_sub)
    end
  end

  defp handle_subscription_deleted(stripe_sub) do
    sub_id = stripe_field(stripe_sub, :id)

    case get_subscription_by_stripe_id(sub_id) do
      %Subscription{} = sub ->
        sub
        |> Subscription.webhook_changeset(%{
          status: "canceled",
          canceled_at:
            from_unix(stripe_field(stripe_sub, :canceled_at)) ||
              DateTime.utc_now() |> DateTime.truncate(:second),
          cancel_at_period_end: false
        })
        |> Repo.update()

      nil ->
        {:ok, :not_found}
    end
  end

  defp handle_payment_succeeded(invoice) do
    subscription_id = stripe_field(invoice, :subscription)

    if subscription_id do
      case get_subscription_by_stripe_id(subscription_id) do
        %Subscription{} = sub ->
          # Update period dates if this is a renewal
          sub
          |> Subscription.webhook_changeset(%{
            status: "active",
            current_period_start: from_unix(stripe_field(invoice, :period_start)),
            current_period_end: from_unix(stripe_field(invoice, :period_end))
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
    subscription_id = stripe_field(invoice, :subscription)

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
    maybe_backfill_customer_from_subscription(subscription)

    subscription
    |> Subscription.webhook_changeset(%{
      stripe_subscription_id: stripe_field(stripe_sub, :id),
      stripe_price_id: get_price_id(stripe_sub),
      status: stripe_field(stripe_sub, :status),
      current_period_start: from_unix(stripe_field(stripe_sub, :current_period_start)),
      current_period_end: from_unix(stripe_field(stripe_sub, :current_period_end)),
      canceled_at: from_unix(stripe_field(stripe_sub, :canceled_at)),
      cancel_at_period_end: stripe_field(stripe_sub, :cancel_at_period_end)
    })
    |> Repo.update()
  end

  defp get_price_id(stripe_sub) do
    items = stripe_field(stripe_sub, :items) || %{}
    data = stripe_field(items, :data) || []

    case data do
      [item | _] ->
        item
        |> stripe_field(:price)
        |> stripe_field(:id)

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

  defp from_unix(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {parsed, ""} -> from_unix(parsed)
      _ -> nil
    end
  end

  defp base_url do
    if Code.ensure_loaded?(ElektrineWeb.Endpoint) do
      ElektrineWeb.Endpoint.url()
    else
      "https://#{Elektrine.Domains.instance_domain()}"
    end
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
    case stripe_client().update_subscription(sub_id, %{cancel_at_period_end: true}) do
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
    case stripe_client().update_subscription(sub_id, %{cancel_at_period_end: false}) do
      {:ok, stripe_sub} ->
        update_from_stripe(subscription, stripe_sub)

      {:error, error} ->
        {:error, error}
    end
  end

  def resume_subscription(_), do: {:error, :no_stripe_subscription}

  defp stripe_client do
    Application.get_env(
      :elektrine,
      :stripe_client,
      Elektrine.Subscriptions.StripeClient.Live
    )
  end

  defp user_stripe_customer_id(%User{stripe_customer_id: cid}) when is_binary(cid) and cid != "",
    do: cid

  defp user_stripe_customer_id(_user), do: nil

  defp billing_email_for(%User{} = user) do
    cond do
      present?(user.recovery_email) and user.recovery_email_verified ->
        String.trim(user.recovery_email)

      present?(user.preferred_email_domain) ->
        EmailAddresses.primary_for_user(user)

      true ->
        EmailAddresses.primary_for_user(user)
    end
  end

  defp maybe_store_user_stripe_customer_id(%User{} = user, customer_id)
       when is_binary(customer_id) and customer_id != "" do
    cond do
      user.stripe_customer_id == customer_id ->
        {:ok, user}

      present?(user.stripe_customer_id) and user.stripe_customer_id != customer_id ->
        Logger.warning(
          "Stripe billing: user #{user.id} already has customer #{inspect(user.stripe_customer_id)}, ignoring #{inspect(customer_id)}"
        )

        {:ok, user}

      customer_id_conflicts?(user.id, customer_id) ->
        Logger.warning(
          "Stripe billing: not backfilling customer #{inspect(customer_id)} for user #{user.id} because multiple customer IDs already exist"
        )

        {:ok, user}

      true ->
        user
        |> Changeset.change(stripe_customer_id: customer_id)
        |> Repo.update()
    end
  end

  defp maybe_store_user_stripe_customer_id(user, _customer_id), do: {:ok, user}

  defp maybe_backfill_customer_from_subscription(%Subscription{
         user_id: user_id,
         stripe_customer_id: customer_id
       })
       when is_binary(customer_id) and customer_id != "" do
    case Repo.get(User, user_id) do
      %User{} = user -> maybe_store_user_stripe_customer_id(user, customer_id)
      nil -> {:ok, :not_found}
    end
  end

  defp maybe_backfill_customer_from_subscription(_subscription), do: {:ok, :noop}

  defp existing_customer_id_for_user(user_id) do
    customer_ids =
      from(s in Subscription,
        where: s.user_id == ^user_id and not is_nil(s.stripe_customer_id),
        distinct: true,
        select: s.stripe_customer_id
      )
      |> Repo.all()

    case customer_ids do
      [] ->
        :none

      [cid] ->
        {:single, cid}

      _ ->
        most_recent_customer_id =
          from(s in Subscription,
            where: s.user_id == ^user_id and not is_nil(s.stripe_customer_id),
            order_by: [desc: s.updated_at, desc: s.inserted_at],
            limit: 1,
            select: s.stripe_customer_id
          )
          |> Repo.one()

        {:multiple, most_recent_customer_id}
    end
  end

  defp customer_id_conflicts?(user_id, customer_id) do
    case existing_customer_id_for_user(user_id) do
      :none -> false
      {:single, ^customer_id} -> false
      {:single, _other} -> true
      {:multiple, _cid} -> true
    end
  end

  defp resolve_webhook_user(customer_id, stripe_sub) do
    metadata_user_id =
      stripe_sub
      |> metadata_value(:user_id)
      |> parse_user_id()

    metadata_user =
      if is_integer(metadata_user_id) do
        Repo.get(User, metadata_user_id)
      end

    cond do
      metadata_user ->
        metadata_user

      present?(customer_id) ->
        get_user_by_stripe_customer_id(customer_id) ||
          get_user_by_subscription_customer_id(customer_id)

      true ->
        nil
    end
  end

  defp get_user_by_stripe_customer_id(customer_id) do
    Repo.get_by(User, stripe_customer_id: customer_id)
  end

  defp get_user_by_subscription_customer_id(customer_id) do
    from(s in Subscription,
      join: u in User,
      on: u.id == s.user_id,
      where: s.stripe_customer_id == ^customer_id,
      limit: 1,
      select: u
    )
    |> Repo.one()
  end

  defp metadata_value(stripe_obj, key) do
    stripe_obj
    |> stripe_field(:metadata)
    |> stripe_field(key)
  end

  defp registration_checkout_session?(session) do
    metadata_value(session, :purpose) == "registration_invite"
  end

  defp parse_user_id(nil), do: nil
  defp parse_user_id(value) when is_integer(value), do: value

  defp parse_user_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_user_id(value), do: parse_user_id(to_string(value))

  defp stripe_field(nil, _key), do: nil

  defp stripe_field(data, key) when is_atom(key) do
    case data do
      %{} ->
        Map.get(data, key) || Map.get(data, Atom.to_string(key))

      _ ->
        nil
    end
  end

  defp normalize_product_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_string_attr(:name)
    |> normalize_string_attr(:slug)
    |> normalize_string_attr(:description)
    |> normalize_string_attr(:billing_type)
    |> normalize_string_attr(:stripe_monthly_price_id)
    |> normalize_string_attr(:stripe_yearly_price_id)
    |> normalize_string_attr(:stripe_one_time_price_id)
    |> normalize_string_attr(:currency)
  end

  defp sync_product_pricing(_product, attrs) do
    Enum.reduce_while(
      [
        {:stripe_monthly_price_id, :monthly_price_cents, "month"},
        {:stripe_yearly_price_id, :yearly_price_cents, "year"},
        {:stripe_one_time_price_id, :one_time_price_cents, :one_time}
      ],
      {:ok, attrs, nil},
      fn {price_id_key, cents_key, interval}, {:ok, acc_attrs, currency} ->
        case sync_price_from_stripe(acc_attrs, price_id_key, cents_key, interval, currency) do
          {:ok, next_attrs, next_currency} ->
            {:cont, {:ok, next_attrs, next_currency}}

          {:error, error} ->
            {:halt, {:error, [error]}}
        end
      end
    )
    |> case do
      {:ok, synced_attrs, _currency} -> {:ok, synced_attrs}
      {:error, errors} -> {:error, errors}
    end
  end

  defp sync_price_from_stripe(attrs, price_id_key, cents_key, interval, current_currency) do
    case attr_value(attrs, price_id_key) do
      price_id when is_binary(price_id) and price_id != "" ->
        with {:ok, stripe_price} <- stripe_client().retrieve_price(price_id),
             {:ok, unit_amount} <- stripe_price_amount(stripe_price, price_id_key),
             {:ok, stripe_currency} <- stripe_price_currency(stripe_price, price_id_key),
             :ok <- validate_price_interval(stripe_price, interval, price_id_key),
             :ok <- validate_price_currency(stripe_currency, current_currency, price_id_key) do
          synced_attrs =
            attrs
            |> put_attr(cents_key, unit_amount)
            |> put_attr(:currency, stripe_currency)

          {:ok, synced_attrs, stripe_currency}
        else
          {:error, reason} when not is_binary(reason) ->
            {:error,
             {price_id_key, "could not sync Stripe price: #{format_stripe_error(reason)}"}}

          {:error, message} ->
            {:error, {price_id_key, message}}
        end

      _ ->
        {:ok, attrs, current_currency}
    end
  end

  defp stripe_price_amount(stripe_price, _field) do
    case stripe_field(stripe_price, :unit_amount) do
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _ -> {:error, "must point to a Stripe price with a fixed unit amount"}
    end
  end

  defp stripe_price_currency(stripe_price, _field) do
    case stripe_field(stripe_price, :currency) do
      currency when is_binary(currency) and currency != "" -> {:ok, String.downcase(currency)}
      _ -> {:error, "must point to a Stripe price with a currency"}
    end
  end

  defp validate_price_interval(stripe_price, expected_interval, _field) do
    recurring = stripe_field(stripe_price, :recurring)
    interval = stripe_field(recurring, :interval)

    case expected_interval do
      :one_time ->
        if is_nil(recurring) do
          :ok
        else
          {:error, "must point to a one-time Stripe price"}
        end

      "year" ->
        if interval == expected_interval do
          :ok
        else
          {:error, "must point to a recurring yearly Stripe price"}
        end

      "month" ->
        if interval == expected_interval do
          :ok
        else
          {:error, "must point to a recurring monthly Stripe price"}
        end
    end
  end

  defp validate_price_currency(_stripe_currency, nil, _field), do: :ok
  defp validate_price_currency(stripe_currency, stripe_currency, _field), do: :ok

  defp validate_price_currency(_stripe_currency, _current_currency, _field) do
    {:error, "must use the same currency as the other Stripe prices for this product"}
  end

  defp product_changeset_with_errors(product, attrs, errors) do
    changeset = change_product(product, attrs)

    Enum.reduce(errors, changeset, fn {field, message}, acc ->
      Changeset.add_error(acc, field, message)
    end)
  end

  defp product_has_subscriptions?(%Product{slug: slug}) do
    Repo.exists?(from(s in Subscription, where: s.product == ^slug))
  end

  defp normalize_string_attr(attrs, key) when is_map(attrs) do
    case attr_value(attrs, key) do
      value when is_binary(value) ->
        put_attr(attrs, key, normalize_optional_string(value))

      _ ->
        attrs
    end
  end

  defp attr_value(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp put_attr(attrs, key, value) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.put(attrs, key, value)

      Map.has_key?(attrs, Atom.to_string(key)) ->
        Map.put(attrs, Atom.to_string(key), value)

      true ->
        Map.put(attrs, key, value)
    end
  end

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(value), do: value

  defp present?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present?(value), do: not is_nil(value)

  defp normalize_checkout_mode(:subscription), do: "subscription"
  defp normalize_checkout_mode(:payment), do: "payment"
  defp normalize_checkout_mode("payment"), do: "payment"
  defp normalize_checkout_mode(_), do: "subscription"

  defp maybe_put_subscription_data(params, "subscription", metadata) do
    Map.put(params, :subscription_data, %{
      metadata: Map.drop(metadata, [:checkout_mode, :price_id])
    })
  end

  defp maybe_put_subscription_data(params, _mode, _metadata), do: params

  defp maybe_put_payment_data(params, "payment", metadata) do
    Map.put(params, :payment_intent_data, %{metadata: metadata})
  end

  defp maybe_put_payment_data(params, _mode, _metadata), do: params

  defp checkout_metadata(user_id, product, price_id, checkout_mode) do
    %{
      user_id: to_string(user_id),
      product: product,
      price_id: price_id,
      checkout_mode: checkout_mode
    }
  end

  defp registration_checkout_metadata(product, price_id, lookup_token) do
    %{
      purpose: "registration_invite",
      product: product,
      price_id: price_id,
      checkout_mode: "payment",
      registration_lookup_token: lookup_token
    }
  end

  defp ensure_registration_checkout_record(product_slug, session, lookup_token_override \\ nil) do
    session_id = stripe_field(session, :id)
    lookup_token = lookup_token_override || metadata_value(session, :registration_lookup_token)

    with true <- present?(session_id),
         true <- present?(lookup_token) do
      attrs = %{
        stripe_checkout_session_id: session_id,
        lookup_token: lookup_token,
        product_slug: product_slug,
        stripe_customer_id: stripe_field(session, :customer),
        stripe_payment_intent_id: stripe_field(session, :payment_intent),
        customer_email: registration_customer_email(session),
        status: "pending"
      }

      _ =
        %RegistrationCheckout{}
        |> RegistrationCheckout.create_changeset(attrs)
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: :stripe_checkout_session_id
        )

      case get_registration_checkout_by_session_id(session_id) do
        %RegistrationCheckout{} = checkout -> {:ok, checkout}
        nil -> {:error, :not_found}
      end
    else
      _ -> {:error, :missing_registration_lookup_token}
    end
  end

  defp get_registration_checkout_by_session_id(session_id) when is_binary(session_id) do
    case Repo.get_by(RegistrationCheckout, stripe_checkout_session_id: String.trim(session_id)) do
      %RegistrationCheckout{} = checkout -> Repo.preload(checkout, :invite_code)
      nil -> nil
    end
  end

  defp registration_customer_email(session) do
    stripe_field(session, :customer_email) ||
      session
      |> stripe_field(:customer_details)
      |> stripe_field(:email)
  end

  defp generate_lookup_token do
    :crypto.strong_rand_bytes(24)
    |> Base.url_encode64(padding: false)
  end

  defp one_time_checkout_metadata(session) do
    %{
      "billing_type" => "one_time",
      "checkout_mode" => stripe_field(session, :mode),
      "checkout_session_id" => stripe_field(session, :id),
      "payment_intent_id" => stripe_field(session, :payment_intent),
      "completed_at" =>
        case from_unix(stripe_field(session, :created)) do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp format_stripe_error(%Stripe.Error{message: message}), do: message
  defp format_stripe_error(reason), do: inspect(reason)
end
