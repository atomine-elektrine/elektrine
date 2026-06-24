defmodule ElektrineWeb.NoteShareHTML do
  use ElektrineWeb, :html

  embed_templates "note_share_html/*"

  def script_json(value) do
    value
    |> Jason.encode!()
    |> escape_script_data()
  end

  defp escape_script_data(json) when is_binary(json) do
    json
    |> String.replace("<", "\\u003C")
    |> String.replace(">", "\\u003E")
    |> String.replace("&", "\\u0026")
    |> String.replace("\u2028", "\\u2028")
    |> String.replace("\u2029", "\\u2029")
  end
end
