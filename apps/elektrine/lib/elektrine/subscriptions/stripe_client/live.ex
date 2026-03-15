defmodule Elektrine.Subscriptions.StripeClient.Live do
  @moduledoc false
  @behaviour Elektrine.Subscriptions.StripeClient

  @impl true
  def create_customer(params), do: Stripe.Customer.create(params)

  @impl true
  def create_checkout_session(params), do: Stripe.Checkout.Session.create(params)

  @impl true
  def create_billing_portal_session(params), do: Stripe.BillingPortal.Session.create(params)

  @impl true
  def update_subscription(subscription_id, params),
    do: Stripe.Subscription.update(subscription_id, params)

  @impl true
  def retrieve_price(price_id), do: Stripe.Price.retrieve(price_id)
end
