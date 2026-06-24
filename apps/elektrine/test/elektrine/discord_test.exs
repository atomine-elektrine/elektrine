defmodule Elektrine.DiscordTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Elektrine.Discord

  test "parses Lanyard presence with Spotify album art URL" do
    request_fun = fn _request, _opts ->
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "success" => true,
             "data" => %{
               "discord_user" => %{
                 "id" => "94490510688792576",
                 "username" => "phin",
                 "global_name" => "Phineas",
                 "avatar" => "avatarhash"
               },
               "discord_status" => "online",
               "activities" => [],
               "spotify" => %{
                 "song" => "Let Go",
                 "artist" => "Ark Patrol",
                 "album" => "Let Go",
                 "album_art_url" => "https://i.scdn.co/image/example",
                 "track_id" => "track-123"
               }
             }
           })
       }}
    end

    assert %{
             username: "Phineas",
             status: "online",
             spotify: %{album_art: "https://i.scdn.co/image/example"}
           } = Discord.get_user_presence("94490510688792576", request_fun: request_fun)
  end

  test "returns nil for Lanyard users that are not monitored" do
    request_fun = fn _request, _opts ->
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"success" => false, "error" => "user not monitored"})
       }}
    end

    log =
      capture_log(fn ->
        assert Discord.get_user_presence("12345678901234567", request_fun: request_fun) == nil
      end)

    assert log =~ "user not monitored"
  end

  test "rejects invalid Discord IDs before building a request" do
    request_fun = fn _request, _opts -> flunk("invalid Discord IDs must not be fetched") end

    assert Discord.get_user_presence("../status?x=1", request_fun: request_fun) == nil
    assert Discord.get_user_presence("123", request_fun: request_fun) == nil
    assert Discord.get_user_presence("1234567890123456", request_fun: request_fun) == nil
  end
end
