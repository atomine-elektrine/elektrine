defmodule ElektrineWeb.Admin.SubscriptionsController do
  @moduledoc """
  Admin controller for managing subscription products and prices.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Subscriptions
  alias Elektrine.Subscriptions.Product

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, _params) do
    products = Subscriptions.list_products()

    render(conn, :subscriptions,
      products: products,
      page_title: "Subscription Products"
    )
  end

  def new(conn, _params) do
    changeset = Subscriptions.change_product(%Product{})
    render(conn, :new_product, changeset: changeset, page_title: "New Product")
  end

  def create(conn, %{"product" => product_params}) do
    # Parse features from textarea (one per line)
    product_params = parse_features(product_params)

    case Subscriptions.create_product(product_params) do
      {:ok, _product} ->
        conn
        |> put_flash(:info, "Product created successfully.")
        |> redirect(to: ~p"/pripyat/subscriptions")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new_product, changeset: changeset, page_title: "New Product")
    end
  end

  def edit(conn, %{"id" => id}) do
    product = Subscriptions.get_product(id)

    if product do
      changeset = Subscriptions.change_product(product)

      render(conn, :edit_product,
        product: product,
        changeset: changeset,
        page_title: "Edit Product"
      )
    else
      conn
      |> put_flash(:error, "Product not found.")
      |> redirect(to: ~p"/pripyat/subscriptions")
    end
  end

  def update(conn, %{"id" => id, "product" => product_params}) do
    product = Subscriptions.get_product(id)

    if product do
      # Parse features from textarea (one per line)
      product_params = parse_features(product_params)

      case Subscriptions.update_product(product, product_params) do
        {:ok, _product} ->
          conn
          |> put_flash(:info, "Product updated successfully.")
          |> redirect(to: ~p"/pripyat/subscriptions")

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :edit_product,
            product: product,
            changeset: changeset,
            page_title: "Edit Product"
          )
      end
    else
      conn
      |> put_flash(:error, "Product not found.")
      |> redirect(to: ~p"/pripyat/subscriptions")
    end
  end

  def delete(conn, %{"id" => id}) do
    product = Subscriptions.get_product(id)

    if product do
      case Subscriptions.delete_product(product) do
        {:ok, _} ->
          conn
          |> put_flash(:info, "Product deleted successfully.")
          |> redirect(to: ~p"/pripyat/subscriptions")

        {:error, _} ->
          conn
          |> put_flash(:error, "Unable to delete product.")
          |> redirect(to: ~p"/pripyat/subscriptions")
      end
    else
      conn
      |> put_flash(:error, "Product not found.")
      |> redirect(to: ~p"/pripyat/subscriptions")
    end
  end

  def toggle(conn, %{"id" => id}) do
    product = Subscriptions.get_product(id)

    if product do
      case Subscriptions.update_product(product, %{active: !product.active}) do
        {:ok, updated} ->
          status = if updated.active, do: "activated", else: "deactivated"

          conn
          |> put_flash(:info, "Product #{status}.")
          |> redirect(to: ~p"/pripyat/subscriptions")

        {:error, _} ->
          conn
          |> put_flash(:error, "Unable to toggle product status.")
          |> redirect(to: ~p"/pripyat/subscriptions")
      end
    else
      conn
      |> put_flash(:error, "Product not found.")
      |> redirect(to: ~p"/pripyat/subscriptions")
    end
  end

  # Parse features from textarea (one feature per line)
  defp parse_features(%{"features" => features} = params) when is_binary(features) do
    parsed =
      features
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "features", parsed)
  end

  defp parse_features(params), do: params
end
