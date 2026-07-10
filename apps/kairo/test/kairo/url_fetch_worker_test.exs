defmodule Kairo.UrlFetchWorkerTest do
  use Kairo.DataCase, async: false

  import Kairo.AccountsFixtures

  alias Kairo.UrlFetchWorker

  @html """
  <html>
    <head>
      <title>Fallback Title</title>
      <meta property="og:title" content="OG Title" />
    </head>
    <body>
      <nav>Skip this navigation</nav>
      <script>ignore();</script>
      <article>
        <h1>Heading</h1>
        <p>First paragraph of the article.</p>
        <p>Second paragraph.</p>
      </article>
      <footer>Skip this footer</footer>
    </body>
  </html>
  """

  defp stub_fetch(fun) do
    Application.put_env(:elektrine, :kairo_url_fetch_fun, fun)
    on_exit(fn -> Application.delete_env(:elektrine, :kairo_url_fetch_fun) end)
  end

  defp stub_request(fun) do
    Application.put_env(:elektrine, :kairo_url_request_fun, fun)
    on_exit(fn -> Application.delete_env(:elektrine, :kairo_url_request_fun) end)
  end

  defp url_source(user, attrs \\ %{}) do
    {:ok, source} =
      Kairo.create_source(
        user,
        Map.merge(%{"source_type" => "url", "url" => "https://example.com/article"}, attrs)
      )

    source
  end

  defp perform(source) do
    UrlFetchWorker.perform(%Oban.Job{
      args: %{"source_id" => source.id, "user_id" => source.user_id}
    })
  end

  describe "extract_html/1" do
    test "prefers og:title and strips chrome from the text" do
      {title, text} = UrlFetchWorker.extract_html(@html)

      assert title == "OG Title"
      assert text =~ "First paragraph of the article."
      assert text =~ "Second paragraph."
      refute text =~ "Skip this navigation"
      refute text =~ "Skip this footer"
      refute text =~ "ignore()"
    end

    test "falls back to the <title> tag" do
      {title, _text} =
        UrlFetchWorker.extract_html(
          "<html><head><title> Only  Title </title></head><body><p>hi</p></body></html>"
        )

      assert title == "Only Title"
    end
  end

  describe "perform/1" do
    test "compiles a url source from fetched HTML" do
      user = user_fixture()
      source = url_source(user)
      assert source.status == "received"
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "kairo:#{user.id}")

      stub_fetch(fn url ->
        {:ok,
         %{
           final_url: url,
           content_type: "text/html",
           title: "OG Title",
           content: "First paragraph of the article.",
           content_format: "text"
         }}
      end)

      assert :ok = perform(source)

      hydrated = Kairo.get_source(user, source.id)
      assert hydrated.status == "compiled"
      assert hydrated.title == "OG Title"
      assert hydrated.content =~ "First paragraph"
      assert hydrated.processed_at
      assert hydrated.metadata["fetched_url"] == "https://example.com/article"
      assert_receive {:kairo_source_updated, source_id}
      assert source_id == source.id
    end

    test "keeps a caller-supplied title" do
      user = user_fixture()
      source = url_source(user, %{"title" => "My Title"})

      stub_fetch(fn url ->
        {:ok,
         %{
           final_url: url,
           content_type: "text/html",
           title: "Fetched Title",
           content: "body",
           content_format: "text"
         }}
      end)

      assert :ok = perform(source)
      assert Kairo.get_source(user, source.id).title == "My Title"
    end

    test "updates storage accounting after hydrating content" do
      user = user_fixture()
      source = url_source(user)
      before_bytes = Repo.get!(Elektrine.Accounts.User, user.id).storage_used_bytes

      stub_fetch(fn url ->
        {:ok,
         %{
           final_url: url,
           content_type: "text/plain",
           title: nil,
           content: String.duplicate("hydrated content ", 1_000),
           content_format: "text"
         }}
      end)

      assert :ok = perform(source)

      after_bytes = Repo.get!(Elektrine.Accounts.User, user.id).storage_used_bytes
      assert after_bytes > before_bytes
      assert after_bytes == Elektrine.Accounts.Storage.calculate_user_storage(user.id)
    end

    test "does not overwrite a source edited while the fetch is in flight" do
      user = user_fixture()
      source = url_source(user)
      test_pid = self()

      stub_fetch(fn url ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :finish_fetch ->
            {:ok,
             %{
               final_url: url,
               content_type: "text/plain",
               title: "Fetched title",
               content: "fetched body",
               content_format: "text"
             }}
        after
          5_000 -> raise "timed out waiting to finish fetch"
        end
      end)

      task = Task.async(fn -> perform(source) end)
      assert_receive {:fetch_started, worker_pid}

      assert {:ok, _edited} =
               Kairo.update_source(user, source.id, %{
                 "title" => "Edited title",
                 "content" => "user-authored body",
                 "metadata" => %{"edited_while_fetching" => true},
                 "status" => "compiled"
               })

      send(worker_pid, :finish_fetch)
      assert {:discard, :source_changed} = Task.await(task)

      preserved = Kairo.get_source(user, source.id)
      assert preserved.status == "compiled"
      assert preserved.title == "Edited title"
      assert preserved.content == "user-authored body"
      assert preserved.metadata == %{"edited_while_fetching" => true}
    end

    test "retries from fresh state after a metadata-only in-flight edit" do
      user = user_fixture()
      source = url_source(user)

      stub_fetch(fn url ->
        assert {:ok, edited} =
                 Kairo.update_source(user, source.id, %{
                   "title" => "Keep this title",
                   "tags" => ["fresh"]
                 })

        assert edited.status == "processing"

        {:ok,
         %{
           final_url: url,
           content_type: "text/plain",
           title: "Stale fetched title",
           content: "stale body",
           content_format: "text"
         }}
      end)

      assert {:error, :source_changed} = perform(source)

      stub_fetch(fn url ->
        {:ok,
         %{
           final_url: url,
           content_type: "text/plain",
           title: "Fresh fetched title",
           content: "fresh body",
           content_format: "text"
         }}
      end)

      assert :ok = perform(source)
      hydrated = Kairo.get_source(user, source.id)
      assert hydrated.title == "Keep this title"
      assert hydrated.tags == ["fresh"]
      assert hydrated.content == "fresh body"
    end

    test "discards cleanly when a source is deleted during the fetch" do
      user = user_fixture()
      source = url_source(user)
      test_pid = self()

      stub_fetch(fn url ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :finish_fetch ->
            {:ok,
             %{
               final_url: url,
               content_type: "text/plain",
               title: nil,
               content: "fetched body",
               content_format: "text"
             }}
        after
          5_000 -> raise "timed out waiting to finish fetch"
        end
      end)

      task = Task.async(fn -> perform(source) end)
      assert_receive {:fetch_started, worker_pid}
      assert {:ok, _deleted} = Kairo.delete_source(user, source.id)

      send(worker_pid, :finish_fetch)
      assert {:discard, :source_not_found} = Task.await(task)
      assert is_nil(Kairo.get_source(user, source.id))
    end

    test "rejects invalid UTF-8 without attempting to persist it" do
      user = user_fixture()
      source = url_source(user)

      stub_fetch(fn url ->
        {:ok,
         %{
           final_url: url,
           content_type: "text/plain",
           title: nil,
           content: <<255, 254>>,
           content_format: "text"
         }}
      end)

      assert {:discard, :invalid_utf8} = perform(source)

      failed = Kairo.get_source(user, source.id)
      assert failed.status == "failed"
      assert failed.error_message == ":invalid_utf8"
      assert is_nil(failed.content)
    end

    test "treats an oversized response as a permanent failure" do
      user = user_fixture()
      source = url_source(user, %{"url" => "https://93.184.216.34/large"})

      stub_request(fn _request -> {:error, :too_large} end)

      assert {:discard, :too_large} = perform(source)
      assert Kairo.get_source(user, source.id).status == "failed"
    end

    test "follows standard redirects" do
      user = user_fixture()
      source = url_source(user, %{"url" => "https://93.184.216.34/start"})
      test_pid = self()

      stub_request(fn request ->
        send(test_pid, {:requested_path, request.path})

        case request.path do
          "/start" ->
            {:ok, %{status: 302, headers: [{"location", "/next"}], body: ""}}

          "/next" ->
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "text/plain; charset=utf-8"}],
               body: "redirected body"
             }}
        end
      end)

      assert :ok = perform(source)
      assert_receive {:requested_path, "/start"}
      assert_receive {:requested_path, "/next"}

      hydrated = Kairo.get_source(user, source.id)
      assert hydrated.content == "redirected body"
      assert hydrated.metadata["fetched_url"] == "https://93.184.216.34/next"
    end

    test "does not treat 304 as a redirect" do
      user = user_fixture()
      source = url_source(user, %{"url" => "https://93.184.216.34/not-modified"})
      test_pid = self()

      stub_request(fn request ->
        send(test_pid, {:requested_path, request.path})
        {:ok, %{status: 304, headers: [{"location", "/must-not-follow"}], body: ""}}
      end)

      assert {:discard, {:http_error, 304}} = perform(source)
      assert_receive {:requested_path, "/not-modified"}
      refute_receive {:requested_path, "/must-not-follow"}
      assert Kairo.get_source(user, source.id).status == "failed"
    end

    test "revalidates redirect destinations before requesting them" do
      user = user_fixture()
      source = url_source(user, %{"url" => "https://93.184.216.34/start"})
      test_pid = self()

      stub_request(fn request ->
        send(test_pid, {:requested_host, request.host})

        {:ok,
         %{
           status: 302,
           headers: [{"location", "http://127.0.0.1/private"}],
           body: ""
         }}
      end)

      assert {:discard, {:unsafe_url, :private_ip}} = perform(source)
      assert_receive {:requested_host, "93.184.216.34"}
      refute_receive {:requested_host, "127.0.0.1"}
      assert Kairo.get_source(user, source.id).status == "failed"
    end

    test "marks the source failed on permanent fetch errors" do
      user = user_fixture()
      source = url_source(user)

      stub_fetch(fn _url -> {:error, {:http_error, 404}, :discard} end)

      assert {:discard, {:http_error, 404}} = perform(source)

      failed = Kairo.get_source(user, source.id)
      assert failed.status == "failed"
      assert failed.error_message =~ "404"
    end

    test "returns an error (retry) on transient fetch failures" do
      user = user_fixture()
      source = url_source(user)

      stub_fetch(fn _url -> {:error, :timeout, :retry} end)

      assert {:error, :timeout} = perform(source)
      assert Kairo.get_source(user, source.id).status == "failed"
    end

    test "discards sources that are not hydratable" do
      user = user_fixture()

      {:ok, note} =
        Kairo.create_source(user, %{
          "source_type" => "markdown",
          "title" => "Note",
          "content" => "already has content"
        })

      assert {:discard, :nothing_to_fetch} = perform(note)

      assert {:discard, :source_not_found} =
               UrlFetchWorker.perform(%Oban.Job{
                 args: %{"source_id" => note.id + 1_000_000, "user_id" => user.id}
               })
    end
  end
end
