defmodule ElektrineWeb.API.PreferenceController do
  @moduledoc """
  JSON API for social client preferences.
  """

  use ElektrineWeb, :controller

  def show(conn, _params) do
    user = conn.assigns[:current_user]

    json(conn, %{
      "posting:default:visibility" => visibility(user.default_post_visibility),
      "posting:default:sensitive" => false,
      "posting:default:language" => language(user.locale),
      "reading:expand:media" => "default",
      "reading:expand:spoilers" => false
    })
  end

  defp visibility("private"), do: "direct"
  defp visibility("friends"), do: "private"
  defp visibility("followers"), do: "private"
  defp visibility("public"), do: "public"
  defp visibility(_), do: "private"

  defp language(locale) when is_binary(locale) and locale != "" do
    locale
    |> String.split(["-", "_"], parts: 2)
    |> List.first()
    |> case do
      language when byte_size(language) == 2 -> String.downcase(language)
      _ -> "en"
    end
  end

  defp language(_), do: "en"
end
