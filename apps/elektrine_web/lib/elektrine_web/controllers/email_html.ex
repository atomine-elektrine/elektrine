defmodule ElektrineWeb.EmailHTML do
  use ElektrineWeb, :html

  embed_templates "email_html/*"

  def format_date(datetime) do
    case datetime do
      %DateTime{} ->
        Calendar.strftime(datetime, "%b %d, %Y %H:%M")

      _ ->
        ""
    end
  end

  def truncate(text, max_length \\ 50), do: Elektrine.TextHelpers.truncate(text, max_length)

  def message_class(message) do
    if message.read do
      "bg-white"
    else
      "bg-blue-50 font-semibold"
    end
  end

  def format_file_size(size) when is_integer(size) do
    cond do
      size >= 1024 * 1024 * 1024 -> "#{Float.round(size / (1024 * 1024 * 1024), 1)} GB"
      size >= 1024 * 1024 -> "#{Float.round(size / (1024 * 1024), 1)} MB"
      size >= 1024 -> "#{Float.round(size / 1024, 1)} KB"
      true -> "#{size} B"
    end
  end

  def format_file_size(_), do: "0 B"
end
