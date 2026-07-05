defmodule Paige.Provider do
  @moduledoc "Behaviour for Paige search providers."

  alias Paige.Result

  @type opts :: keyword()
  @type result :: Result.t() | map()

  @callback search(String.t(), opts()) :: {:ok, [result()]} | {:error, term()}
end
