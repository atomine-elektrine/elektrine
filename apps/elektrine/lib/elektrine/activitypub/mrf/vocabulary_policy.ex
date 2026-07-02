defmodule Elektrine.ActivityPub.MRF.VocabularyPolicy do
  @moduledoc """
  Allows or rejects ActivityStreams vocabulary terms by type.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  @impl true
  def filter(%{"type" => "Undo", "object" => object} = activity) do
    with {:ok, _object} <- filter(object) do
      {:ok, activity}
    end
  end

  def filter(%{"type" => type} = activity) do
    config = Application.get_env(:elektrine, :mrf_vocabulary, [])
    accept = Keyword.get(config, :accept, [])
    reject = Keyword.get(config, :reject, [])

    cond do
      accept != [] and type not in accept ->
        {:reject, "[VocabularyPolicy] #{type} not in accept list"}

      type in reject ->
        {:reject, "[VocabularyPolicy] #{type} in reject list"}

      is_map(activity["object"]) ->
        with {:ok, _object} <- filter(activity["object"]) do
          {:ok, activity}
        end

      true ->
        {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok, %{mrf_vocabulary: Application.get_env(:elektrine, :mrf_vocabulary, []) |> Map.new()}}
  end
end
