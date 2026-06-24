defmodule Elektrine.StaticSites.GitHubDeployWorkerSecurityTest do
  use ExUnit.Case, async: true

  alias Elektrine.Profiles.StaticSiteDeployment
  alias Elektrine.StaticSites.GitHubDeployWorker

  defp deployment do
    %StaticSiteDeployment{
      repo_owner: "octo",
      repo_name: "site",
      branch: "main"
    }
  end

  test "fetch_archive requests raw bounded zip streaming" do
    request_fun = fn url, opts ->
      assert url == "https://codeload.github.com/octo/site/zip/refs/heads/main"
      assert {"accept", "application/zip"} in opts[:headers]
      assert {"accept-encoding", "identity"} in opts[:headers]
      assert opts[:compressed] == false
      assert opts[:decode_body] == false
      assert opts[:raw] == true
      assert is_function(opts[:into], 2)

      {:ok, %{status: 200, body: "zip-bytes"}}
    end

    assert {:ok, "zip-bytes"} =
             GitHubDeployWorker.fetch_archive(deployment(), request_fun: request_fun)
  end

  test "fetch_archive collects streamed chunks" do
    request_fun = fn _url, opts ->
      request = Req.new()
      response = Req.Response.new(status: 200)
      collector = opts[:into]

      {:cont, {request, response}} = collector.({:data, "zip-"}, {request, response})
      {:cont, {_request, response}} = collector.({:data, "bytes"}, {request, response})

      {:ok, response}
    end

    assert {:ok, "zip-bytes"} =
             GitHubDeployWorker.fetch_archive(deployment(), request_fun: request_fun)
  end

  test "fetch_archive rejects streamed archives that exceed the cap" do
    response =
      Req.Response.new(status: 200)
      |> Req.Response.put_private(:elektrine_github_archive_too_large, true)

    request_fun = fn _url, _opts -> {:ok, response} end

    assert {:error, :archive_too_large} =
             GitHubDeployWorker.fetch_archive(deployment(), request_fun: request_fun)
  end
end
