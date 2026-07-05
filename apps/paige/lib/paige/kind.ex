defmodule Paige.Kind do
  @moduledoc "Normalizes the result kinds shared by Paige and its providers."

  @kinds [:web, :images, :videos, :news]

  def all, do: @kinds

  def normalize(kind) when kind in @kinds, do: kind

  def normalize(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> do_normalize()
  end

  def normalize(_kind), do: :web

  defp do_normalize("image"), do: :images
  defp do_normalize("images"), do: :images
  defp do_normalize("video"), do: :videos
  defp do_normalize("videos"), do: :videos
  defp do_normalize("news"), do: :news
  defp do_normalize(_kind), do: :web
end
