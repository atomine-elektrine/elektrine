defmodule Maid.Provider do
  @moduledoc "Behaviour for Maid search providers."

  alias Maid.Result

  @type opts :: keyword()
  @type result :: Result.t() | map()

  @callback search(String.t(), opts()) :: {:ok, [result()]} | {:error, term()}
end
