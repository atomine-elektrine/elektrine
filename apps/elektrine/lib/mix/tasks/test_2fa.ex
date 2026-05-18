defmodule Mix.Tasks.Test2fa do
  @moduledoc false
  @shortdoc "Tests 2FA secret generation and current codes"

  use Mix.Task

  def run([secret]) do
    Mix.Task.run("app.start")

    IO.puts("Secret length: #{String.length(secret)}")

    # Generate current code
    current_code = NimbleTOTP.verification_code(secret)
    reveal? = System.get_env("TEST_2FA_REVEAL_CODES") in ["1", "true", "TRUE", "yes", "YES"]

    if reveal? do
      IO.puts("Current server code: #{current_code}")
    else
      IO.puts("Current server code: [redacted; set TEST_2FA_REVEAL_CODES=true to print]")
    end

    # Test codes for next few time periods
    current_time = System.os_time(:second)
    IO.puts("\nCodes for next few periods:")

    for offset <- -2..2 do
      time = current_time + offset * 30
      code = NimbleTOTP.verification_code(secret, time: time)
      timestamp = DateTime.from_unix!(time) |> DateTime.to_string()
      if reveal?, do: IO.puts("#{timestamp}: #{code}"), else: IO.puts("#{timestamp}: [redacted]")
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
