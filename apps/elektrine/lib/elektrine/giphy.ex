defmodule Elektrine.Giphy do
  @moduledoc """
  Giphy API client for fetching GIFs.
  """

  require Logger

  @doc """
  Searches for GIFs using the Giphy API.
  """
  def search_gifs(query, opts \\ []) do
    # Input validation and sanitization
    query =
      query
      |> String.trim()
      # Limit query length
      |> String.slice(0, 100)
      # Only allow alphanumeric, spaces, hyphens
      |> String.replace(~r/[^\w\s-]/, "")

    # Limit between 1-50
    limit = Keyword.get(opts, :limit, 50) |> max(1) |> min(50)
    rating = Keyword.get(opts, :rating, "pg-13")

    config = Application.get_env(:elektrine, :giphy)
    api_key = config[:api_key]
    base_url = config[:base_url]

    if api_key == "your_giphy_api_key_here" do
      # Fallback to mock data if no API key is configured
      get_mock_gifs(query)
    else
      url = "#{base_url}/gifs/search"

      params = %{
        api_key: api_key,
        q: query,
        limit: limit,
        rating: rating,
        lang: "en"
      }

      query_string = URI.encode_query(params)
      full_url = "#{url}?#{query_string}"

      request = Finch.build(:get, full_url)

      case Finch.request(request, Elektrine.Finch) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"data" => gifs}} ->
              parsed_gifs = Enum.map(gifs, &parse_gif_data/1)
              {:ok, parsed_gifs}

            {:error, _} ->
              Logger.error("Failed to parse Giphy response")
              {:error, :parse_error}
          end

        {:ok, %Finch.Response{status: status}} ->
          Logger.error("Giphy API returned status #{status}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("Failed to call Giphy API: #{inspect(reason)}")
          {:error, :network_error}
      end
    end
  end

  @doc """
  Gets trending GIFs from Giphy.
  """
  def trending_gifs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    rating = Keyword.get(opts, :rating, "pg-13")

    config = Application.get_env(:elektrine, :giphy)
    api_key = config[:api_key]
    base_url = config[:base_url]

    if api_key == "your_giphy_api_key_here" do
      # Fallback to mock data if no API key is configured
      get_mock_gifs("trending")
    else
      url = "#{base_url}/gifs/trending"

      params = %{
        api_key: api_key,
        limit: limit,
        rating: rating
      }

      query_string = URI.encode_query(params)
      full_url = "#{url}?#{query_string}"

      request = Finch.build(:get, full_url)

      case Finch.request(request, Elektrine.Finch) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"data" => gifs}} ->
              parsed_gifs = Enum.map(gifs, &parse_gif_data/1)
              {:ok, parsed_gifs}

            {:error, _} ->
              Logger.error("Failed to parse Giphy trending response")
              {:error, :parse_error}
          end

        {:ok, %Finch.Response{status: status}} ->
          Logger.error("Giphy trending API returned status #{status}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("Failed to call Giphy trending API: #{inspect(reason)}")
          {:error, :network_error}
      end
    end
  end

  # Private helper functions

  defp parse_gif_data(gif_data) do
    %{
      id: gif_data["id"],
      title: gif_data["title"] || "GIF",
      url:
        get_in(gif_data, ["images", "fixed_height", "url"]) ||
          get_in(gif_data, ["images", "original", "url"]),
      preview_url:
        get_in(gif_data, ["images", "fixed_height_small", "url"]) ||
          get_in(gif_data, ["images", "fixed_height", "url"]),
      width: get_in(gif_data, ["images", "fixed_height", "width"]),
      height: get_in(gif_data, ["images", "fixed_height", "height"])
    }
  end

  # Mock GIF data when no API key is configured
  defp get_mock_gifs(query) do
    gif_database = %{
      "happy" => [
        %{
          id: "1",
          title: "Happy",
          url: "https://media.giphy.com/media/l3q2K5jinAlChoCLS/giphy.gif",
          preview_url: "https://media.giphy.com/media/l3q2K5jinAlChoCLS/giphy.gif"
        },
        %{
          id: "2",
          title: "Joy",
          url: "https://media.giphy.com/media/26uf2JHNV0Tq3ugkE/giphy.gif",
          preview_url: "https://media.giphy.com/media/26uf2JHNV0Tq3ugkE/giphy.gif"
        }
      ],
      "gg" => [
        %{
          id: "3",
          title: "Good Game",
          url: "https://media.giphy.com/media/2wKbtCMHTVoOY/giphy.gif",
          preview_url: "https://media.giphy.com/media/2wKbtCMHTVoOY/giphy.gif"
        },
        %{
          id: "4",
          title: "Victory",
          url: "https://media.giphy.com/media/xT9IgMw9fhuVGUHGwE/giphy.gif",
          preview_url: "https://media.giphy.com/media/xT9IgMw9fhuVGUHGwE/giphy.gif"
        }
      ],
      "lol" => [
        %{
          id: "5",
          title: "Laughing",
          url: "https://media.giphy.com/media/3o7buirYcmV5nSwIRW/giphy.gif",
          preview_url: "https://media.giphy.com/media/3o7buirYcmV5nSwIRW/giphy.gif"
        },
        %{
          id: "6",
          title: "Funny",
          url: "https://media.giphy.com/media/10JhviFuU2gWD6/giphy.gif",
          preview_url: "https://media.giphy.com/media/10JhviFuU2gWD6/giphy.gif"
        }
      ],
      "trending" => [
        %{
          id: "7",
          title: "trending",
          url: "https://media.giphy.com/media/l3q2K5jinAlChoCLS/giphy.gif",
          preview_url: "https://media.giphy.com/media/l3q2K5jinAlChoCLS/giphy.gif"
        },
        %{
          id: "8",
          title: "trending",
          url: "https://media.giphy.com/media/2wKbtCMHTVoOY/giphy.gif",
          preview_url: "https://media.giphy.com/media/2wKbtCMHTVoOY/giphy.gif"
        },
        %{
          id: "9",
          title: "trending",
          url: "https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy.gif",
          preview_url: "https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy.gif"
        }
      ]
    }

    search_term = String.downcase(query)

    # Find matching GIFs
    Enum.reduce(gif_database, [], fn {keyword, gifs}, acc ->
      if String.contains?(keyword, search_term) or String.contains?(search_term, keyword) do
        acc ++ gifs
      else
        acc
      end
    end)
    |> Enum.take(50)
  end
end
