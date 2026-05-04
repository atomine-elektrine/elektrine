defmodule ElektrineWeb.DAV.DriveController do
  use ElektrineWeb, :controller

  alias Elektrine.Drive
  alias ElektrineWeb.CanonicalURL
  alias ElektrineWeb.DAV.ResponseHelpers

  @body_read_chunk_size 1_048_576
  @body_read_timeout 15_000

  def propfind_home(conn, %{"username" => username}) do
    user = conn.assigns.current_user

    cond do
      not Drive.user_can_access?(user) ->
        ResponseHelpers.send_forbidden(conn)

      user.username != username ->
        ResponseHelpers.send_forbidden(conn)

      true ->
        base_url = base_url(conn)
        depth = ResponseHelpers.get_depth(conn)

        responses = [
          %{
            href: dav_href(base_url, username, ""),
            propstat: [{200, collection_props("Drive", user, username, "", base_url)}]
          }
        ]

        responses =
          if depth != 0 do
            {:ok, folder_view} = Drive.list_folder(user.id, "")
            responses ++ folder_children_responses(folder_view, base_url, username)
          else
            responses
          end

        ResponseHelpers.send_multistatus(conn, responses)
    end
  end

  def propfind_resource(conn, %{"username" => username} = params) do
    user = conn.assigns.current_user
    path = dav_path(params)

    if user.username != username or not Drive.user_can_access?(user) do
      ResponseHelpers.send_forbidden(conn)
    else
      cond do
        path == "" ->
          propfind_home(conn, %{"username" => username})

        file = Drive.get_file_by_path(user.id, path) ->
          ResponseHelpers.send_multistatus(conn, [
            %{
              href: dav_href(base_url(conn), username, path, false),
              propstat: [{200, file_props(file)}]
            }
          ])

        true ->
          case Drive.list_folder(user.id, path) do
            {:ok, folder_view} ->
              depth = ResponseHelpers.get_depth(conn)
              base_url = base_url(conn)

              responses = [
                %{
                  href: dav_href(base_url, username, path),
                  propstat: [
                    {200, collection_props(Path.basename(path), user, username, path, base_url)}
                  ]
                }
              ]

              responses =
                if depth != 0,
                  do: responses ++ folder_children_responses(folder_view, base_url, username),
                  else: responses

              ResponseHelpers.send_multistatus(conn, responses)

            {:error, _} ->
              ResponseHelpers.send_not_found(conn)
          end
      end
    end
  end

  def mkcol(conn, %{"username" => username} = params) do
    user = conn.assigns.current_user
    path = dav_path(params)

    if user.username != username or not Drive.user_can_access?(user) do
      ResponseHelpers.send_forbidden(conn)
    else
      case Drive.create_folder(user.id, path) do
        {:ok, _folder} -> ResponseHelpers.send_created(conn)
        {:error, :path_taken} -> send_resp(conn, 405, "Collection already exists")
        {:error, _reason} -> send_resp(conn, 409, "Could not create folder")
      end
    end
  end

  def get_file(conn, %{"username" => username} = params) do
    user = conn.assigns.current_user
    path = dav_path(params)

    if user.username != username or not Drive.user_can_access?(user) do
      ResponseHelpers.send_forbidden(conn)
    else
      with %Drive.StoredFile{} = file <- Drive.get_file_by_path(user.id, path),
           {:ok, binary} <- Drive.read_file(file) do
        ResponseHelpers.send_resource(conn, binary, file.content_type, dav_etag(file))
      else
        _ -> ResponseHelpers.send_not_found(conn)
      end
    end
  end

  def put_file(conn, %{"username" => username} = params) do
    user = conn.assigns.current_user
    path = dav_path(params)

    if user.username != username or not Drive.user_can_access?(user) do
      ResponseHelpers.send_forbidden(conn)
    else
      case read_limited_body(conn, Drive.max_upload_size()) do
        {:ok, body, conn} ->
          existing = Drive.get_file_by_path(user.id, path)

          case Drive.put_file_content(user, path, body,
                 content_type: List.first(get_req_header(conn, "content-type"))
               ) do
            {:ok, file} ->
              if existing do
                ResponseHelpers.send_no_content(conn, dav_etag(file))
              else
                ResponseHelpers.send_created(conn, dav_etag(file))
              end

            {:error, _reason} ->
              send_resp(conn, 409, "Could not save file")
          end

        {:error, :too_large, conn} ->
          send_resp(conn, 413, "Request body too large")

        {:error, _reason, conn} ->
          send_resp(conn, 400, "Could not read request body")
      end
    end
  end

  def delete_resource(conn, %{"username" => username} = params) do
    user = conn.assigns.current_user
    path = dav_path(params)

    if user.username != username or not Drive.user_can_access?(user) do
      ResponseHelpers.send_forbidden(conn)
    else
      case Drive.get_file_by_path(user.id, path) do
        file when not is_nil(file) ->
          case Drive.delete_file(user.id, file.id) do
            :ok -> ResponseHelpers.send_no_content(conn)
            {:error, _reason} -> send_resp(conn, 500, "Failed to delete file")
          end

        _ ->
          case Drive.delete_folder(user.id, path) do
            :ok -> ResponseHelpers.send_no_content(conn)
            {:error, _reason} -> ResponseHelpers.send_not_found(conn)
          end
      end
    end
  end

  def move_resource(conn, %{"username" => username} = params) do
    user = conn.assigns.current_user
    source_path = dav_path(params)

    if user.username != username or not Drive.user_can_access?(user) do
      ResponseHelpers.send_forbidden(conn)
    else
      with [destination] <- get_req_header(conn, "destination"),
           {:ok, destination_path} <- parse_destination(destination, username) do
        case Drive.get_file_by_path(user.id, source_path) do
          file when not is_nil(file) ->
            case Drive.rename_file(user.id, file.id, Path.basename(destination_path)) do
              {:ok, renamed} ->
                case Drive.move_file(
                       user.id,
                       renamed.id,
                       Path.dirname(destination_path) |> normalize_destination_folder()
                     ) do
                  {:ok, _file} -> ResponseHelpers.send_created(conn)
                  {:error, _reason} -> send_resp(conn, 409, "Could not move file")
                end

              {:error, _reason} ->
                send_resp(conn, 409, "Could not move file")
            end

          _ ->
            case Drive.move_folder(
                   user.id,
                   source_path,
                   Path.dirname(destination_path) |> normalize_destination_folder(),
                   Path.basename(destination_path)
                 ) do
              {:ok, _path} -> ResponseHelpers.send_created(conn)
              {:error, _reason} -> send_resp(conn, 409, "Could not move folder")
            end
        end
      else
        _ -> send_resp(conn, 400, "Invalid destination")
      end
    end
  end

  defp folder_children_responses(folder_view, base_url, username) do
    folder_responses =
      Enum.map(folder_view.folders, fn folder ->
        %{
          href: dav_href(base_url, username, folder.path),
          propstat: [{200, collection_props(folder.name, nil, username, folder.path, base_url)}]
        }
      end)

    file_responses =
      Enum.map(folder_view.files, fn file ->
        %{
          href: dav_href(base_url, username, file.path, false),
          propstat: [{200, file_props(file)}]
        }
      end)

    folder_responses ++ file_responses
  end

  defp read_limited_body(conn, max_size) do
    if content_length_exceeds?(conn, max_size) do
      {:error, :too_large, conn}
    else
      do_read_limited_body(conn, max_size, 0, [])
    end
  end

  defp do_read_limited_body(conn, max_size, bytes_read, chunks) do
    case Plug.Conn.read_body(conn,
           length: @body_read_chunk_size,
           read_length: @body_read_chunk_size,
           read_timeout: @body_read_timeout
         ) do
      {:ok, chunk, conn} ->
        finish_limited_body(conn, max_size, bytes_read, chunks, chunk)

      {:more, chunk, conn} ->
        continue_limited_body(conn, max_size, bytes_read, chunks, chunk)

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp continue_limited_body(conn, max_size, bytes_read, chunks, chunk) do
    bytes_read = bytes_read + byte_size(chunk)

    if bytes_read > max_size do
      {:error, :too_large, conn}
    else
      do_read_limited_body(conn, max_size, bytes_read, [chunk | chunks])
    end
  end

  defp finish_limited_body(conn, max_size, bytes_read, chunks, chunk) do
    bytes_read = bytes_read + byte_size(chunk)

    if bytes_read > max_size do
      {:error, :too_large, conn}
    else
      {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
    end
  end

  defp content_length_exceeds?(conn, max_size) do
    conn
    |> get_req_header("content-length")
    |> List.first()
    |> case do
      nil ->
        false

      content_length ->
        case Integer.parse(content_length) do
          {length, ""} when length > max_size -> true
          _ -> false
        end
    end
  end

  defp collection_props(display_name, user, username, path, base_url) do
    owner_username = if user, do: user.username, else: username

    [
      displayname: if(display_name in [nil, ""], do: "Drive", else: display_name),
      resourcetype: :collection,
      creationdate: DateTime.utc_now() |> DateTime.truncate(:second),
      current_user_principal: "#{base_url}/principals/users/#{owner_username}/",
      owner: "#{base_url}/principals/users/#{owner_username}/",
      getetag: Base.encode16(:crypto.hash(:sha256, (path == "" && "root") || path), case: :lower)
    ]
  end

  defp file_props(file) do
    [
      displayname: file.original_filename,
      resourcetype: nil,
      getcontenttype: file.content_type,
      getcontentlength: file.size,
      getlastmodified: file.updated_at,
      creationdate: file.inserted_at,
      getetag: dav_etag(file)
    ]
  end

  defp dav_etag(file) do
    Base.encode16(:crypto.hash(:sha256, "#{file.path}:#{file.updated_at}:#{file.size}"),
      case: :lower
    )
  end

  defp dav_path(%{"path" => path}) when is_list(path),
    do: Enum.join(path, "/") |> String.trim("/")

  defp dav_path(_params), do: ""

  defp parse_destination(destination, username) do
    uri = URI.parse(destination)
    prefix = "/drive-dav/#{username}/"

    cond do
      is_nil(uri.path) ->
        {:error, :invalid_destination}

      uri.path == "/drive-dav/#{username}" ->
        {:ok, ""}

      String.starts_with?(uri.path, prefix) ->
        {:ok, String.trim_leading(uri.path, prefix) |> String.trim("/")}

      true ->
        {:error, :invalid_destination}
    end
  end

  defp normalize_destination_folder("."), do: ""
  defp normalize_destination_folder("/"), do: ""
  defp normalize_destination_folder(path), do: String.trim(path || "", "/")

  defp dav_href(base_url, username, path, trailing_slash \\ true)

  defp dav_href(base_url, username, "", trailing_slash) do
    suffix = if trailing_slash, do: "/", else: ""
    "#{base_url}/drive-dav/#{username}#{suffix}"
  end

  defp dav_href(base_url, username, path, trailing_slash) do
    suffix = if trailing_slash, do: "/", else: ""
    "#{base_url}/drive-dav/#{username}/#{path}#{suffix}"
  end

  defp base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    CanonicalURL.base_url(scheme)
  end
end
