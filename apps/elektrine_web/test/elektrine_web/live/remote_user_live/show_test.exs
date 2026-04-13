defmodule ElektrineSocialWeb.RemoteUserLive.ShowTest do
  use ExUnit.Case, async: true

  alias Elektrine.AppCache
  alias ElektrineSocialWeb.RemoteUserLive.Show

  test "handles record_dwell_times for anonymous users" do
    socket = %{assigns: %{current_user: nil}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "record_dwell_times",
               %{
                 "views" => [
                   %{
                     "post_id" => "200202",
                     "dwell_time_ms" => 2452,
                     "scroll_depth" => 1,
                     "expanded" => false,
                     "source" => "remote_profile"
                   }
                 ]
               },
               socket
             )

    assert {:noreply, ^socket} =
             Show.handle_event("record_dwell_times", %{"views" => "invalid"}, socket)
  end

  test "handles record_dwell_time for anonymous users" do
    socket = %{assigns: %{current_user: nil}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "record_dwell_time",
               %{
                 "post_id" => "200202",
                 "dwell_time_ms" => 2452,
                 "scroll_depth" => 1,
                 "expanded" => false,
                 "source" => "remote_profile"
               },
               socket
             )
  end

  test "handles record_dismissal for anonymous users" do
    socket = %{assigns: %{current_user: nil}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "record_dismissal",
               %{
                 "post_id" => "200202",
                 "type" => "scrolled_past",
                 "dwell_time_ms" => 100
               },
               socket
             )
  end

  test "navigates embedded post URLs" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}

    assert {:noreply, updated_socket} =
             Show.handle_event(
               "navigate_to_embedded_post",
               %{"url" => "/timeline/post/42"},
               socket
             )

    assert inspect(updated_socket.redirected) =~ "/timeline/post/42"
  end

  test "sort_posts normalizes remote collection totals for top and hot sorts" do
    low_score_post = %{
      "id" => "https://remote.example/posts/low",
      "published" => "2026-01-01T00:00:00Z",
      "likes" => %{"totalItems" => "2"}
    }

    high_score_post = %{
      "id" => "https://remote.example/posts/high",
      "published" => "2026-01-01T00:00:00Z",
      "likes" => %{"totalItems" => "12"}
    }

    assert [^high_score_post, ^low_score_post] =
             Show.sort_posts([low_score_post, high_score_post], "top")

    assert [^high_score_post, ^low_score_post] =
             Show.sort_posts([low_score_post, high_score_post], "hot")
  end

  test "retries loading remote community stats while cache is still empty" do
    actor_id = System.unique_integer([:positive])
    AppCache.put_remote_user_community_stats(actor_id, %{members: 0, posts: 0})

    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          remote_actor: %{id: actor_id},
          community_stats: %{members: 0, posts: 0}
        }
      }

    assert {:noreply, ^socket} =
             Show.handle_info({:reload_remote_user_community_stats, actor_id, 1}, socket)

    assert_receive {:reload_remote_user_community_stats, ^actor_id, 2}, 1_700
  end

  test "loads remote community stats immediately once cache is populated" do
    actor_id = System.unique_integer([:positive])
    stats = %{members: 24_719, posts: 29_067}
    AppCache.put_remote_user_community_stats(actor_id, stats)

    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          remote_actor: %{id: actor_id},
          community_stats: %{members: 0, posts: 0}
        }
      }

    assert {:noreply, ^socket} =
             Show.handle_info({:reload_remote_user_community_stats, actor_id, 1}, socket)

    assert_receive {:community_stats_loaded, ^stats}
  end
end
