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
