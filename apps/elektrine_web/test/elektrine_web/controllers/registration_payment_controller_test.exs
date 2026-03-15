defmodule ElektrineWeb.RegistrationPaymentControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.Repo
  alias Elektrine.Subscriptions.{Product, RegistrationCheckout}

  defmodule FakeStripeClient do
    @behaviour Elektrine.Subscriptions.StripeClient

    @impl true
    def create_customer(_params), do: {:error, :unsupported}

    @impl true
    def create_checkout_session(params), do: dispatch(:create_checkout_session, params)

    @impl true
    def create_billing_portal_session(_params), do: {:error, :unsupported}

    @impl true
    def update_subscription(_subscription_id, _params), do: {:error, :unsupported}

    @impl true
    def retrieve_price(_price_id), do: {:error, :unsupported}

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

    Process.put(
      {FakeStripeClient, :create_checkout_session},
      fn _payload -> flunk("unexpected Stripe checkout session call") end
    )

    on_exit(fn ->
      if previous_client do
        Application.put_env(:elektrine, :stripe_client, previous_client)
      else
        Application.delete_env(:elektrine, :stripe_client)
      end
    end)

    :ok
  end

  test "POST /register/purchase redirects to Stripe checkout", %{conn: conn} do
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
      {:ok, %{id: "cs_reg_redirect", url: "https://checkout.test/register"}}
    end)

    conn = post(conn, ~p"/register/purchase")
    assert redirected_to(conn) == "https://checkout.test/register"
  end

  test "GET /register/purchase/success shows the issued invite code", %{conn: conn} do
    {:ok, invite_code} = Accounts.create_invite_code(%{max_uses: 1, note: "paid"})

    Repo.insert!(%RegistrationCheckout{
      stripe_checkout_session_id: "cs_reg_success",
      lookup_token: "access-token",
      product_slug: "registration",
      status: "fulfilled",
      invite_code_id: invite_code.id
    })

    conn =
      get(
        conn,
        ~p"/register/purchase/success?checkout_session_id=cs_reg_success&access=access-token"
      )

    response = html_response(conn, 200)

    assert response =~ "Invite Ready"
    assert response =~ invite_code.code
    assert response =~ "/register?invite_code=#{invite_code.code}"
  end

  test "GET /register/purchase/success shows a pending state before fulfillment", %{conn: conn} do
    Repo.insert!(%RegistrationCheckout{
      stripe_checkout_session_id: "cs_reg_pending",
      lookup_token: "pending-token",
      product_slug: "registration",
      status: "pending"
    })

    conn =
      get(
        conn,
        ~p"/register/purchase/success?checkout_session_id=cs_reg_pending&access=pending-token"
      )

    response = html_response(conn, 200)

    assert response =~ "Payment Received"
    assert response =~ "still being matched to an invite code"
  end

  defp expect_stripe(name, fun) do
    Process.put({FakeStripeClient, name}, fun)
  end
end
