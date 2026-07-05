defmodule Paige.Result do
  @moduledoc "A normalized Paige search result."

  @type t :: %__MODULE__{
          title: String.t(),
          url: String.t(),
          snippet: String.t() | nil,
          source: String.t() | nil,
          score: number(),
          published_at: DateTime.t() | nil,
          metadata: map()
        }

  defstruct title: "",
            url: "",
            snippet: nil,
            source: nil,
            score: 0,
            published_at: nil,
            metadata: %{}
end
