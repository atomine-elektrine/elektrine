defmodule ElektrineWeb.AtominePowTest do
  use Elektrine.DataCase, async: false

  alias Atomine.Attestations
  alias ElektrineWeb.AtominePow

  setup do
    previous_config = Application.get_env(:elektrine, :atomine_pow, [])
    on_exit(fn -> Application.put_env(:elektrine, :atomine_pow, previous_config) end)
    :ok
  end

  test "verifies an anonymous effort token at the configured difficulty" do
    Application.put_env(:elektrine, :atomine_pow, difficulty: 0, skip_verification: false)
    token = effort_token!(0)

    assert {:ok, :verified} = AtominePow.verify(token, "registration", "127.0.0.1")
  end

  test "rejects tokens below the configured difficulty" do
    Application.put_env(:elektrine, :atomine_pow, difficulty: 1, skip_verification: false)
    token = effort_token!(0)

    assert {:error, :insufficient_difficulty} =
             AtominePow.verify(token, "registration", "127.0.0.1")
  end

  defp effort_token!(difficulty) do
    {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: difficulty)

    {:ok, attestation} =
      Attestations.issue_anonymous_effort_token(%{
        "challenge" => challenge.challenge,
        "solution" => "0"
      })

    attestation.artifact
  end
end
