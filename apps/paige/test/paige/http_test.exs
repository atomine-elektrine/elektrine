defmodule Paige.HTTPTest do
  use ExUnit.Case, async: true

  test "decodes successful JSON responses and forwards a bounded timeout" do
    request_fun = fn url, headers, request_opts ->
      assert url == "https://search.example.test"
      assert headers == [{"Accept", "application/json"}]
      assert request_opts[:receive_timeout] == 15_000
      {:ok, %{status: 200, body: ~s({"results":[]})}}
    end

    assert Paige.HTTP.get_json(
             "https://search.example.test",
             [{"Accept", "application/json"}],
             request_fun: request_fun,
             timeout: 30_000
           ) == {:ok, %{"results" => []}}
  end

  test "classifies malformed JSON, authentication errors, and transport failures" do
    malformed = fn _url, _headers, _opts -> {:ok, %{status: 200, body: "not-json"}} end
    unauthorized = fn _url, _headers, _opts -> {:ok, %{status: 401, body: ""}} end
    forbidden = fn _url, _headers, _opts -> {:ok, %{status: 403, body: ""}} end
    offline = fn _url, _headers, _opts -> {:error, :econnrefused} end

    assert Paige.HTTP.get_json("https://example.test", [], request_fun: malformed) ==
             {:error, :invalid_json}

    assert Paige.HTTP.get_json("https://example.test", [], request_fun: unauthorized) ==
             {:error, :unauthorized}

    assert Paige.HTTP.get_json("https://example.test", [], request_fun: forbidden) ==
             {:error, :forbidden}

    assert Paige.HTTP.get_json("https://example.test", [], request_fun: offline) ==
             {:error, :econnrefused}
  end

  test "preserves bounded Retry-After guidance for rate limits" do
    request_fun = fn _url, _headers, _opts ->
      {:ok, %{status: 429, body: "", headers: [{"Retry-After", "120"}]}}
    end

    assert Paige.HTTP.get_json("https://example.test", [], request_fun: request_fun) ==
             {:error, {:rate_limited, 120}}
  end

  test "contains exceptions from request adapters" do
    request_fun = fn _url, _headers, _opts -> raise "adapter failed" end

    assert Paige.HTTP.get_json("https://example.test", [], request_fun: request_fun) ==
             {:error, :request_failed}
  end

  test "returns successful HTML bodies and shares HTTP error classification" do
    html = fn _url, _headers, opts ->
      assert opts[:receive_timeout] == 100
      {:ok, %{status: 200, body: "<html>results</html>"}}
    end

    limited = fn _url, _headers, _opts ->
      {:ok, %{status: 429, body: "", headers: [{"retry-after", "15"}]}}
    end

    assert Paige.HTTP.get_text("https://search.test", [], request_fun: html, timeout: 1) ==
             {:ok, "<html>results</html>"}

    assert Paige.HTTP.get_text("https://search.test", [], request_fun: limited) ==
             {:error, {:rate_limited, 15}}
  end
end
