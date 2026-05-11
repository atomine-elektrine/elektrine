defmodule ElektrineWeb.AtominePow do
  @moduledoc false

  @default_difficulty 18

  def enabled? do
    Code.ensure_loaded?(Atomine.Attestations) and not skip_verification?()
  end

  def difficulty do
    config()
    |> Keyword.get(:difficulty, @default_difficulty)
    |> normalize_difficulty()
  end

  def verify(token, audience, nonce \\ nil) do
    cond do
      skip_verification?() ->
        {:ok, :verified}

      not Elektrine.Strings.present?(token) ->
        {:error, :missing_token}

      not Code.ensure_loaded?(Atomine.Attestations) ->
        {:error, :unavailable}

      true ->
        required_difficulty = difficulty()

        case Atomine.Attestations.redeem_anonymous_effort_token(token, %{
               "audience" => audience,
               "nonce" => nonce
             }) do
          {:ok, %{difficulty: token_difficulty}} ->
            if token_difficulty >= required_difficulty do
              {:ok, :verified}
            else
              {:error, :insufficient_difficulty}
            end

          {:ok, _attestation} ->
            {:error, :insufficient_difficulty}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp skip_verification? do
    config()
    |> Keyword.get(:skip_verification, false)
    |> truthy?()
  end

  defp config, do: Application.get_env(:elektrine, :atomine_pow, []) || []

  defp normalize_difficulty(value) when is_integer(value), do: value |> max(0) |> min(30)

  defp normalize_difficulty(value) when is_binary(value) do
    case Integer.parse(value) do
      {difficulty, ""} -> normalize_difficulty(difficulty)
      _ -> @default_difficulty
    end
  end

  defp normalize_difficulty(_value), do: @default_difficulty

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
