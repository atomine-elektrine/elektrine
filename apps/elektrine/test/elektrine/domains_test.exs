defmodule Elektrine.DomainsTest do
  use ExUnit.Case, async: true

  alias Elektrine.Domains

  setup do
    previous_port = System.get_env("PORT")
    previous_environment = Application.get_env(:elektrine, :environment)

    on_exit(fn ->
      if is_nil(previous_port),
        do: System.delete_env("PORT"),
        else: System.put_env("PORT", previous_port)

      if is_nil(previous_environment) do
        Application.delete_env(:elektrine, :environment)
      else
        Application.put_env(:elektrine, :environment, previous_environment)
      end
    end)

    :ok
  end

  test "uses http with configured port for local development domains" do
    Application.put_env(:elektrine, :environment, :dev)
    System.put_env("PORT", "4100")

    assert Domains.inferred_base_url_for_domain("localhost") == "http://localhost:4100"
  end

  test "uses https without port for public tunnel domains in development" do
    Application.put_env(:elektrine, :environment, :dev)
    System.put_env("PORT", "4100")

    assert Domains.inferred_base_url_for_domain("z.example.com") == "https://z.example.com"
  end

  test "uses https without port in production" do
    Application.put_env(:elektrine, :environment, :prod)
    System.put_env("PORT", "4100")

    assert Domains.inferred_base_url_for_domain("localhost") == "https://localhost"
  end
end
