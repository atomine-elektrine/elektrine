defmodule ElektrineWeb.API.StaticSiteController do
  @moduledoc """
  External API controller for static site deployments.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Domains
  alias Elektrine.Profiles
  alias Elektrine.StaticSites
  alias ElektrineWeb.API.Response
  alias ElektrineWeb.GitHubOIDC

  @doc """
  GET /api/ext/v1/static-site
  """
  def show(conn, _params) do
    user = conn.assigns.current_user
    files = StaticSites.list_files(user.id)

    Response.ok(conn, %{
      static_site: static_site_payload(conn, user, files)
    })
  end

  @doc """
  POST /api/ext/v1/static-site/deploy
  """
  def deploy(conn, %{"site" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user
    replace? = replace_upload?(params)

    with {:ok, zip_binary} <- File.read(upload.path),
         {:ok, count} <- upload_site(user, zip_binary, replace?),
         {:ok, _profile} <- ensure_static_profile_mode(user) do
      files = StaticSites.list_files(user.id)

      Response.created(conn, %{
        message: "Static site deployed",
        uploaded_files: count,
        replaced: replace?,
        static_site: static_site_payload(conn, user, files)
      })
    else
      {:error, reason} -> deploy_error(conn, reason)
    end
  end

  def deploy(conn, _params) do
    Response.error(
      conn,
      :bad_request,
      "missing_site_upload",
      "Upload a ZIP file in multipart field `site`."
    )
  end

  def deploy_github(conn, %{"site" => %Plug.Upload{} = upload}) do
    with {:ok, claims} <- verify_github_oidc(conn),
         {:ok, deployment} <- deployment_for_claims(claims),
         {:ok, zip_binary} <- File.read(upload.path),
         {:ok, count} <- StaticSites.replace_with_zip(deployment.user, zip_binary),
         {:ok, _profile} <- ensure_static_profile_mode(deployment.user),
         {:ok, _deployment} <- StaticSites.mark_deployment_deployed(deployment) do
      files = StaticSites.list_files(deployment.user_id)

      Response.created(conn, %{
        message: "Static site deployed",
        uploaded_files: count,
        replaced: true,
        static_site: static_site_payload(conn, deployment.user, files)
      })
    else
      {:error, :missing_token} ->
        Response.error(conn, :unauthorized, "missing_token", "GitHub OIDC token required")

      {:error, :invalid_github_oidc_token} ->
        Response.error(
          conn,
          :unauthorized,
          "invalid_github_oidc_token",
          "Invalid GitHub OIDC token"
        )

      {:error, :deployment_not_linked} ->
        Response.error(
          conn,
          :forbidden,
          "deployment_not_linked",
          "This GitHub repository is not linked to a static site"
        )

      {:error, :branch_not_allowed} ->
        Response.error(
          conn,
          :forbidden,
          "branch_not_allowed",
          "This branch is not allowed to deploy"
        )

      {:error, reason} ->
        deploy_error(conn, reason)
    end
  end

  def deploy_github(conn, _params), do: deploy(conn, %{})

  def github_webhook(conn, params) do
    raw_body = conn.assigns[:raw_body] || conn.private[:cached_body]
    event = conn |> get_req_header("x-github-event") |> List.first()

    with {:ok, deployment} <- webhook_deployment(params),
         :ok <- verify_webhook_signature(conn, raw_body, deployment.webhook_secret),
         :ok <- verify_webhook_branch(params, deployment) do
      if event == "push" do
        _ = StaticSites.enqueue_github_deploy(deployment)
      end

      json(conn, %{received: true})
    else
      {:error, :missing_raw_body} ->
        conn |> put_status(:bad_request) |> json(%{error: "missing_body"})

      {:error, :missing_signature} ->
        conn |> put_status(:bad_request) |> json(%{error: "missing_signature"})

      {:error, :invalid_signature} ->
        conn |> put_status(:forbidden) |> json(%{error: "invalid_signature"})

      {:error, :deployment_not_linked} ->
        conn |> put_status(:not_found) |> json(%{error: "deployment_not_linked"})

      {:error, :branch_not_allowed} ->
        json(conn, %{received: true, ignored: true})
    end
  end

  defp upload_site(user, zip_binary, true), do: StaticSites.replace_with_zip(user, zip_binary)
  defp upload_site(user, zip_binary, false), do: StaticSites.upload_zip(user, zip_binary)

  defp verify_github_oidc(conn) do
    with {:ok, token} <- bearer_token(conn) do
      github_oidc_verifier().verify(token, github_oidc_audience(conn))
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp github_oidc_verifier do
    Application.get_env(:elektrine_web, :github_oidc_verifier, GitHubOIDC)
  end

  defp github_oidc_audience(_conn), do: url(~p"/api/ext/v1/static-site/deploy/github")

  defp deployment_for_claims(%{"repository" => repository, "ref" => "refs/heads/" <> branch}) do
    with [owner, repo] <- String.split(repository, "/", parts: 2),
         deployment when not is_nil(deployment) <-
           StaticSites.get_static_site_deployment_by_github_repo(owner, repo),
         true <- deployment.branch == branch do
      {:ok, deployment}
    else
      false -> {:error, :branch_not_allowed}
      _ -> {:error, :deployment_not_linked}
    end
  end

  defp deployment_for_claims(_claims), do: {:error, :deployment_not_linked}

  defp webhook_deployment(%{"repository" => %{"full_name" => full_name}}) do
    with [owner, repo] <- String.split(full_name, "/", parts: 2),
         deployment when not is_nil(deployment) <-
           StaticSites.get_static_site_deployment_by_github_repo(owner, repo) do
      {:ok, deployment}
    else
      _ -> {:error, :deployment_not_linked}
    end
  end

  defp webhook_deployment(_params), do: {:error, :deployment_not_linked}

  defp verify_webhook_branch(%{"ref" => "refs/heads/" <> branch}, deployment) do
    if deployment.branch == branch do
      :ok
    else
      {:error, :branch_not_allowed}
    end
  end

  defp verify_webhook_branch(_params, _deployment), do: :ok

  defp verify_webhook_signature(conn, raw_body, secret) when is_binary(raw_body) do
    case get_req_header(conn, "x-hub-signature-256") do
      ["sha256=" <> signature | _] ->
        expected =
          :hmac
          |> :crypto.mac(:sha256, secret, raw_body)
          |> Base.encode16(case: :lower)

        if byte_size(signature) == byte_size(expected) and
             Plug.Crypto.secure_compare(String.downcase(signature), expected) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :missing_signature}
    end
  end

  defp verify_webhook_signature(_conn, _raw_body, _secret), do: {:error, :missing_raw_body}

  defp replace_upload?(params) do
    case Map.get(params, "replace", "true") do
      value when value in [true, "true", "1", "yes", "on"] -> true
      _ -> false
    end
  end

  defp ensure_static_profile_mode(user) do
    case StaticSites.enable_static_mode(user.id) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :profile_not_found} ->
        Profiles.create_user_profile(user.id, %{
          profile_mode: "static",
          display_name: user.username
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp static_site_payload(conn, user, files) do
    has_homepage? = Enum.any?(files, &(&1.path in ["index.html", "index.htm"]))

    %{
      url: static_site_url(conn, user),
      file_count: length(files),
      storage_bytes: StaticSites.total_storage_used(user.id),
      has_homepage: has_homepage?,
      files: Enum.map(files, &file_payload/1)
    }
  end

  defp static_site_url(conn, user) do
    Domains.profile_url_for_user(user, conn.host) || "/#{user.handle || user.username}"
  end

  defp file_payload(file) do
    %{
      path: file.path,
      content_type: file.content_type,
      size: file.size,
      updated_at: file.updated_at
    }
  end

  defp deploy_error(conn, :file_limit_exceeded) do
    Response.error(
      conn,
      :unprocessable_entity,
      "file_limit_exceeded",
      "Static sites support up to 1000 files"
    )
  end

  defp deploy_error(conn, :storage_limit_exceeded) do
    Response.error(
      conn,
      :unprocessable_entity,
      "storage_limit_exceeded",
      "Static site storage limit exceeded"
    )
  end

  defp deploy_error(conn, :file_too_large) do
    Response.error(conn, :unprocessable_entity, "file_too_large", "Static site ZIP is too large")
  end

  defp deploy_error(conn, :invalid_file_type) do
    Response.error(
      conn,
      :unprocessable_entity,
      "invalid_file_type",
      "Static site ZIP contains an unsupported file type"
    )
  end

  defp deploy_error(conn, :invalid_path) do
    Response.error(
      conn,
      :unprocessable_entity,
      "invalid_path",
      "Static site ZIP contains an unsafe file path"
    )
  end

  defp deploy_error(conn, :invalid_content) do
    Response.error(
      conn,
      :unprocessable_entity,
      "invalid_content",
      "Static site ZIP contains invalid file content"
    )
  end

  defp deploy_error(conn, :zip_bomb_detected) do
    Response.error(
      conn,
      :unprocessable_entity,
      "zip_bomb_detected",
      "Static site ZIP expands too much"
    )
  end

  defp deploy_error(conn, {:invalid_zip, _reason}) do
    Response.error(
      conn,
      :unprocessable_entity,
      "invalid_zip",
      "Upload must be a valid ZIP archive"
    )
  end

  defp deploy_error(conn, {:partial_upload, errors}) do
    Response.error(
      conn,
      :unprocessable_entity,
      "partial_upload",
      "Only part of the site uploaded",
      %{errors: inspect(errors)}
    )
  end

  defp deploy_error(conn, {:upload_failed, reason}) do
    Response.error(
      conn,
      :unprocessable_entity,
      "upload_failed",
      "Static site storage backend failed",
      %{reason: inspect(reason)}
    )
  end

  defp deploy_error(conn, reason) do
    Response.error(conn, :unprocessable_entity, "deploy_failed", "Static site deploy failed", %{
      reason: inspect(reason)
    })
  end
end
