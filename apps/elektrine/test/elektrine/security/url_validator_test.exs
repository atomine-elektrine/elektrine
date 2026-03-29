defmodule Elektrine.Security.URLValidatorTest do
  use ExUnit.Case, async: true

  alias Elektrine.Security.URLValidator

  describe "validate/1" do
    test "trims trailing root dots before host classification" do
      result =
        URLValidator.validate(
          "https://openpgpkey.example.localhost./.well-known/openpgpkey/example.localhost./hu/test"
        )

      assert result in [{:error, :private_domain}, {:error, :private_ip}]
    end
  end
end
