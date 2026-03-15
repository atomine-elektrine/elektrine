defmodule Elektrine.Subscriptions.StripeClient do
  @moduledoc false

  @callback create_customer(map()) :: {:ok, map()} | {:error, term()}
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback create_billing_portal_session(map()) :: {:ok, map()} | {:error, term()}
  @callback update_subscription(binary(), map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_price(binary()) :: {:ok, map()} | {:error, term()}
end
