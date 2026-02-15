defmodule ElektrineWeb.Plugs.Locale do
  @moduledoc """
  Plug to set the locale for the current request based on user preferences,
  session, or browser headers.
  """
  import Plug.Conn

  @supported_locales ~w(en zh)
  @default_locale "en"

  def init(default), do: default

  def call(conn, _default) do
    # Priority order:
    # 1. URL params (for explicit switching)
    # 2. User preference (if logged in)
    # 3. Session (persists across requests)
    # 4. Browser headers (auto-detect)
    # 5. Default
    locale =
      get_locale_from_params(conn) ||
        get_locale_from_user(conn) ||
        get_locale_from_session(conn) ||
        get_locale_from_headers(conn) ||
        @default_locale

    # Ensure the locale is supported
    locale = if locale in @supported_locales, do: locale, else: @default_locale

    # Set the locale for Gettext
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    # Store in session for future requests
    conn
    |> put_session(:locale, locale)
    |> assign(:locale, locale)
  end

  # Get locale from URL params (?locale=es)
  defp get_locale_from_params(conn) do
    conn.params["locale"]
  end

  # Get locale from session
  defp get_locale_from_session(conn) do
    get_session(conn, :locale)
  end

  # Get locale from user preferences (if logged in)
  defp get_locale_from_user(conn) do
    case conn.assigns[:current_user] do
      %{locale: locale} when is_binary(locale) ->
        locale

      _ ->
        nil
    end
  end

  # Get locale from Accept-Language header
  defp get_locale_from_headers(conn) do
    case get_req_header(conn, "accept-language") do
      [accept_language | _] ->
        accept_language
        |> parse_accept_language()
        |> find_supported_locale()

      _ ->
        nil
    end
  end

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_with_quality/1)
    |> Enum.sort_by(fn {_lang, quality} -> quality end, :desc)
    |> Enum.map(fn {lang, _quality} -> normalize_language_code(lang) end)
  end

  defp parse_language_with_quality(lang_string) do
    case String.split(lang_string, ";") do
      [lang] ->
        {String.trim(lang), 1.0}

      [lang, quality_str] ->
        quality =
          case Regex.run(~r/q=([0-9.]+)/, quality_str) do
            [_, q_value] ->
              case Float.parse(q_value) do
                {q, _} -> q
                :error -> 1.0
              end

            _ ->
              1.0
          end

        {String.trim(lang), quality}

      _ ->
        {String.trim(lang_string), 1.0}
    end
  end

  defp normalize_language_code(lang) do
    # Convert "zh-CN" -> "zh", "en-US" -> "en", etc.
    lang
    |> String.downcase()
    |> String.split("-")
    |> List.first()
  end

  defp find_supported_locale(languages) do
    Enum.find(languages, &(&1 in @supported_locales))
  end

  @doc """
  Returns the list of supported locales with their display names.
  """
  def supported_locales do
    [
      {"en", "English"},
      {"zh", "中文"}
    ]
  end
end
