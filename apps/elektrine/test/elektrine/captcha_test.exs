defmodule Elektrine.CaptchaTest do
  use ExUnit.Case, async: true

  alias Elektrine.Captcha

  test "generated captcha verifies with its answer" do
    {_image_binary, answer, token} = Captcha.generate()

    assert :ok = Captcha.verify(token, answer)
  end

  test "malformed answer hashes fail closed instead of raising" do
    token = Base.encode64("#{System.system_time(:second)}:short")

    assert {:error, :wrong_answer} = Captcha.verify(token, "1")
  end
end
