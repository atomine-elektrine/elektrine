defmodule ElektrineWeb.GitHubWebhooks do
  @moduledoc false

  @github_api "https://api.github.com"

  def ensure_push_webhook(access_token, owner, repo, callback_url, secret) do
    body = %{
      name: "web",
      active: true,
      events: ["push"],
      config: %{
        url: callback_url,
        content_type: "json",
        secret: secret,
        insecure_ssl: "0"
      }
    }

    case Req.post("#{@github_api}/repos/#{owner}/#{repo}/hooks",
           json: body,
           headers: github_headers(access_token)
         ) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 ->
        {:ok, to_string(id)}

      {:ok, %{status: 422}} ->
        {:ok, nil}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_webhook_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_headers(access_token) do
    [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer #{access_token}"},
      {"user-agent", "Elektrine"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end
end
