defmodule Elektrine.WebIndex.ExtractorTest do
  use ExUnit.Case, async: true

  alias Elektrine.WebIndex.Extractor

  test "extracts metadata and keeps only crawlable same-host links" do
    html = """
    <html lang="en-US">
      <head>
        <title>  Independent Search </title>
        <meta name="description" content="A focused search index">
        <link rel="canonical" href="/guide">
      </head>
      <body>
        <nav>Navigation noise</nav>
        <main><h1>Paige crawler</h1><p>Useful searchable content for everyone.</p></main>
        <a href="/next#section">Next</a>
        <a href="https://elsewhere.example/page">External</a>
        <a href="/manual.pdf">PDF</a>
      </body>
    </html>
    """

    assert {:ok, extracted} = Extractor.extract(html, "https://example.com/start")
    assert extracted.title == "Independent Search"
    assert extracted.description == "A focused search index"
    assert extracted.canonical_url == "https://example.com/guide"
    assert extracted.language == "en"
    assert extracted.content =~ "Useful searchable content"
    refute extracted.content =~ "Navigation noise"
    assert extracted.links == ["https://example.com/next"]
  end

  test "honors noindex metadata" do
    assert {:ok, extracted} =
             Extractor.extract(
               "<html><head><meta name='robots' content='nofollow, noindex'></head><body>Hidden page content</body></html>",
               "https://example.com/hidden"
             )

    assert extracted.noindex?
  end
end
