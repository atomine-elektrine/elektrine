defmodule Elektrine.SubscriptionsTest do
  use Elektrine.DataCase, async: false

  alias Ecto.Changeset
  alias Elektrine.Accounts.User
  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo
  alias Elektrine.Subscriptions
  alias Elektrine.Subscriptions.{Product, RegistrationCheckout, Subscription}

  defmodule FakeStripeClient do
    @behaviour Elektrine.Subscriptions.StripeClient

    @impl true
    def create_customer(params), do: dispatch(:create_customer, params)

    @impl true
    def create_checkout_session(params), do: dispatch(:create_checkout_session, params)

    @impl true
    def create_billing_portal_session(params),
      do: dispatch(:create_billing_portal_session, params)

    @impl true
    def update_subscription(subscription_id, params),
      do: dispatch(:update_subscription, {subscription_id, params})

    @impl true
    def retrieve_price(price_id), do: dispatch(:retrieve_price, price_id)

    defp dispatch(name, payload) do
      case Process.get({__MODULE__, name}) do
        fun when is_function(fun, 1) -> fun.(payload)
        nil -> raise "missing fake Stripe expectation for #{inspect(name)}"
      end
    end
  end

  setup do
    previous_client = Application.get_env(:elektrine, :stripe_client)
    Application.put_env(:elektrine, :stripe_client, FakeStripeClient)

    for key <- [
          :create_customer,
          :create_checkout_session,
          :create_billing_portal_session,
          :update_subscription,
          :retrieve_price
        ] do
      Process.put(
        {FakeStripeClient, key},
        fn _payload -> flunk("unexpected Stripe client call for #{inspect(key)}") end
      )
    end

    on_exit(fn ->
      if previous_client do
        Application.put_env(:elektrine, :stripe_client, previous_client)
      else
        Application.delete_env(:elektrine, :stripe_client)
      end
    end)

    :ok
  end

  test "create_product syncs pricing and currency from Stripe price IDs" do
    expect_stripe(:retrieve_price, fn
      "price_month" ->
        {:ok, %{unit_amount: 1900, currency: "usd", recurring: %{interval: "month"}}}

      "price_year" ->
        {:ok, %{unit_amount: 19_000, currency: "usd", recurring: %{interval: "year"}}}
    end)

    attrs = %{
      "name" => "VPN",
      "slug" => "vpn",
      "stripe_monthly_price_id" => "price_month",
      "stripe_yearly_price_id" => "price_year",
      "monthly_price_cents" => "1",
      "yearly_price_cents" => "2",
      "currency" => "eur"
    }

    assert {:ok, product} = Subscriptions.create_product(attrs)
    assert product.monthly_price_cents == 1900
    assert product.yearly_price_cents == 19_000
    assert product.currency == "usd"
  end

  test "create_product syncs one-time pricing from Stripe" do
    expect_stripe(:retrieve_price, fn
      "price_once" ->
        {:ok, %{unit_amount: 500, currency: "usd", recurring: nil}}
    end)

    attrs = %{
      "name" => "Registration",
      "slug" => "registration",
      "billing_type" => "one_time",
      "stripe_one_time_price_id" => "price_once",
      "one_time_price_cents" => "1",
      "currency" => "eur"
    }

    assert {:ok, product} = Subscriptions.create_product(attrs)
    assert product.billing_type == "one_time"
    assert product.one_time_price_cents == 500
    assert product.currency == "usd"
  end

  test "create_product rejects mixed recurring and one-time pricing" do
    assert {:error, changeset} =
             Subscriptions.create_product(%{
               "name" => "Registration",
               "slug" => "registration",
               "billing_type" => "one_time",
               "monthly_price_cents" => "100"
             })

    assert "one-time products cannot include monthly or yearly pricing" in errors_on(changeset).billing_type
  end

  test "update_product rejects slug changes" do
    product =
      Repo.insert!(%Product{
        name: "VPN",
        slug: "vpn",
        currency: "usd",
        active: true
      })

    assert {:error, changeset} =
             Subscriptions.update_product(product, %{
               "name" => "VPN Plus",
               "slug" => "vpn-plus"
             })

    assert "cannot be changed after creation" in errors_on(changeset).slug
  end

  test "delete_product blocks products with subscription history" do
    user = AccountsFixtures.user_fixture()

    product =
      Repo.insert!(%Product{
        name: "VPN",
        slug: "vpn",
        currency: "usd",
        active: true
      })

    Repo.insert!(%Subscription{
      user_id: user.id,
      product: product.slug,
      stripe_customer_id: "cus_existing",
      status: "active"
    })

    assert {:error, :has_subscriptions} = Subscriptions.delete_product(product)
  end

  test "get_or_create_stripe_customer stores the Stripe customer on the user" do
    user =
      AccountsFixtures.user_fixture(%{username: "billinguser"})
      |> then(fn user ->
        user
        |> Changeset.change(
          recovery_email: "billing@example.com",
          recovery_email_verified: true
        )
        |> Repo.update!()
      end)

    expect_stripe(:create_customer, fn params ->
      assert params.email == "billing@example.com"
      assert params.metadata.user_id == Integer.to_string(user.id)
      {:ok, %{id: "cus_new"}}
    end)

    assert {:ok, "cus_new"} = Subscriptions.get_or_create_stripe_customer(user, "vpn")
    assert Repo.get!(User, user.id).stripe_customer_id == "cus_new"
  end

  test "get_or_create_stripe_customer reuses a single existing customer ID" do
    user = AccountsFixtures.user_fixture()

    Repo.insert!(%Subscription{
      user_id: user.id,
      product: "mail",
      stripe_customer_id: "cus_existing",
      status: "active"
    })

    assert {:ok, "cus_existing"} = Subscriptions.get_or_create_stripe_customer(user, "vpn")
    assert Repo.get!(User, user.id).stripe_customer_id == "cus_existing"
  end

  test "create_checkout_session uses the subscribe success query param by default" do
    user =
      AccountsFixtures.user_fixture()
      |> then(fn user ->
        user
        |> Changeset.change(stripe_customer_id: "cus_checkout")
        |> Repo.update!()
      end)

    expect_stripe(:create_checkout_session, fn params ->
      assert params.customer == "cus_checkout"
      assert params.success_url == "#{expected_base_url()}/subscribe/vpn?success=true"
      assert params.cancel_url == "#{expected_base_url()}/subscribe/vpn"
      {:ok, %{url: "https://checkout.test/session"}}
    end)

    assert {:ok, %{url: "https://checkout.test/session"}} =
             Subscriptions.create_checkout_session(user, "vpn", "price_month")
  end

  test "create_checkout_session supports one-time payment mode" do
    user =
      AccountsFixtures.user_fixture()
      |> then(fn user ->
        user
        |> Changeset.change(stripe_customer_id: "cus_checkout")
        |> Repo.update!()
      end)

    expect_stripe(:create_checkout_session, fn params ->
      assert params.customer == "cus_checkout"
      assert params.mode == "payment"
      assert params.metadata.checkout_mode == "payment"
      assert params.metadata.price_id == "price_once"
      assert params.payment_intent_data.metadata.product == "registration"
      {:ok, %{url: "https://checkout.test/session"}}
    end)

    assert {:ok, %{url: "https://checkout.test/session"}} =
             Subscriptions.create_checkout_session(user, "registration", "price_once",
               checkout_mode: :payment
             )
  end

  test "create_registration_checkout_session creates a guest payment checkout" do
    product =
      Repo.insert!(%Product{
        name: "Registration",
        slug: "registration",
        billing_type: "one_time",
        currency: "usd",
        active: true,
        one_time_price_cents: 500,
        stripe_one_time_price_id: "price_once"
      })

    expect_stripe(:create_checkout_session, fn params ->
      assert params.mode == "payment"
      assert params.customer_creation == "always"
      assert params.metadata.purpose == "registration_invite"
      assert params.metadata.product == product.slug
      assert params.metadata.price_id == product.stripe_one_time_price_id

      assert params.success_url =~
               "/register/purchase/success?checkout_session_id={CHECKOUT_SESSION_ID}&access="

      {:ok, %{id: "cs_reg_123", url: "https://checkout.test/registration"}}
    end)

    assert {:ok, %{url: "https://checkout.test/registration"}} =
             Subscriptions.create_registration_checkout_session(product)

    assert %RegistrationCheckout{
             stripe_checkout_session_id: "cs_reg_123",
             product_slug: "registration",
             status: "pending"
           } =
             Repo.get_by!(RegistrationCheckout, stripe_checkout_session_id: "cs_reg_123")
  end

  test "subscription created webhook falls back to customer lookup when metadata user_id is invalid" do
    user =
      AccountsFixtures.user_fixture()
      |> then(fn user ->
        user
        |> Changeset.change(stripe_customer_id: "cus_webhook")
        |> Repo.update!()
      end)

    Repo.insert!(%Product{
      name: "VPN",
      slug: "vpn",
      currency: "usd",
      active: true,
      stripe_monthly_price_id: "price_month"
    })

    event = %{
      type: "customer.subscription.created",
      data: %{
        object: %{
          "id" => "sub_123",
          "customer" => "cus_webhook",
          "status" => "active",
          "metadata" => %{"user_id" => "not-an-int", "product" => "vpn"},
          "items" => %{"data" => [%{"price" => %{"id" => "price_month"}}]},
          "current_period_start" => 1_700_000_000,
          "current_period_end" => 1_700_086_400,
          "cancel_at_period_end" => false
        }
      }
    }

    assert {:ok, _subscription} = Subscriptions.process_webhook_event(event)

    assert %Subscription{} = subscription = Subscriptions.get_subscription(user.id, "vpn")
    assert subscription.status == "active"
    assert subscription.stripe_customer_id == "cus_webhook"
    assert subscription.stripe_subscription_id == "sub_123"
  end

  test "checkout session completed creates one-time access" do
    user =
      AccountsFixtures.user_fixture()
      |> then(fn user ->
        user
        |> Changeset.change(stripe_customer_id: "cus_once")
        |> Repo.update!()
      end)

    Repo.insert!(%Product{
      name: "Registration",
      slug: "registration",
      billing_type: "one_time",
      currency: "usd",
      active: true,
      one_time_price_cents: 500,
      stripe_one_time_price_id: "price_once"
    })

    event = %{
      type: "checkout.session.completed",
      data: %{
        object: %{
          "id" => "cs_123",
          "mode" => "payment",
          "payment_status" => "paid",
          "customer" => "cus_once",
          "payment_intent" => "pi_123",
          "created" => 1_700_000_000,
          "metadata" => %{
            "user_id" => Integer.to_string(user.id),
            "product" => "registration",
            "price_id" => "price_once",
            "checkout_mode" => "payment"
          }
        }
      }
    }

    assert {:ok, %Subscription{} = subscription} = Subscriptions.process_webhook_event(event)
    assert subscription.user_id == user.id
    assert subscription.product == "registration"
    assert subscription.status == "active"
    assert subscription.stripe_subscription_id == nil
    assert subscription.stripe_price_id == "price_once"
    assert subscription.metadata["billing_type"] == "one_time"
  end

  test "checkout session completed for registration invite creates a single-use invite" do
    Repo.insert!(%Product{
      name: "Registration",
      slug: "registration",
      billing_type: "one_time",
      currency: "usd",
      active: true,
      one_time_price_cents: 500,
      stripe_one_time_price_id: "price_once"
    })

    event = %{
      type: "checkout.session.completed",
      data: %{
        object: %{
          "id" => "cs_reg_456",
          "mode" => "payment",
          "payment_status" => "paid",
          "customer" => "cus_guest",
          "payment_intent" => "pi_reg_456",
          "customer_email" => "payer@example.com",
          "created" => 1_700_000_000,
          "metadata" => %{
            "purpose" => "registration_invite",
            "product" => "registration",
            "price_id" => "price_once",
            "checkout_mode" => "payment",
            "registration_lookup_token" => "lookup-token"
          }
        }
      }
    }

    assert {:ok, %RegistrationCheckout{} = checkout} = Subscriptions.process_webhook_event(event)
    assert checkout.status == "fulfilled"
    assert checkout.lookup_token == "lookup-token"
    assert checkout.product_slug == "registration"
    assert checkout.customer_email == "payer@example.com"
    assert checkout.invite_code_id

    checkout = Repo.preload(checkout, :invite_code, force: true)
    assert checkout.invite_code.max_uses == 1
    assert checkout.invite_code.is_active
  end

  defp expect_stripe(name, fun) do
    Process.put({FakeStripeClient, name}, fun)
  end

  defp expected_base_url do
    endpoint = Module.concat([ElektrineWeb, Endpoint])

    if Code.ensure_loaded?(endpoint) do
      apply(endpoint, :url, [])
    else
      "https://#{Elektrine.Domains.instance_domain()}"
    end
  end
end
