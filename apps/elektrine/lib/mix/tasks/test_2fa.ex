defmodule Mix.Tasks.Test2fa do
  @moduledoc false
  @shortdoc "Tests 2FA secret generation and current codes"

  use Mix.Task

  def run([secret]) do
    Mix.Task.run("app.start")

    IO.puts("Testing secret: #{secret}")
    IO.puts("Secret length: #{String.length(secret)}")

    # Generate current code
    current_code = NimbleTOTP.verification_code(secret)
    IO.puts("Current server code: #{current_code}")

    # Test codes for next few time periods
    current_time = System.os_time(:second)
    IO.puts("\nCodes for next few periods:")

    for offset <- -2..2 do
      time = current_time + offset * 30
      code = NimbleTOTP.verification_code(secret, time: time)
      timestamp = DateTime.from_unix!(time) |> DateTime.to_string()
      IO.puts("#{timestamp}: #{code}")
    end

    # Test validation with window
    IO.puts("\nTesting validation with window=2:")
    test_result = NimbleTOTP.valid?(secret, current_code, window: 2)
    IO.puts("Self-validation result: #{test_result}")
  end

  def run([]) do
    IO.puts("Usage: mix test_2fa <secret>")
    IO.puts("Example: mix test_2fa ABCD1234EFGH5678IJKL")
  end
end
