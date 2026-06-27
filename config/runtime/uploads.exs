import Config

present? = fn value -> is_binary(value) and String.trim(value) != "" end

known_placeholder_secret? = fn value ->
  normalized = if is_binary(value), do: value |> String.trim() |> String.downcase(), else: ""

  normalized in [
    "change-me",
    "replace-me",
    "replace-with-long-random-secret",
    "example-secret-access-key",
    "<generate-a-long-random-secret>",
    "<provider-access-key-id>",
    "<provider-secret-access-key>"
  ]
end

real_secret? = fn value -> present?.(value) and not known_placeholder_secret?.(value) end

s3_access_key_id = System.get_env("S3_ACCESS_KEY_ID") || System.get_env("MAGPIE_S3_ACCESS_KEY_ID")

s3_secret_access_key =
  System.get_env("S3_SECRET_ACCESS_KEY") || System.get_env("MAGPIE_S3_SECRET_ACCESS_KEY")

s3_endpoint = System.get_env("S3_ENDPOINT") || System.get_env("MAGPIE_ENDPOINT")
s3_bucket_name = System.get_env("S3_BUCKET_NAME") || System.get_env("MAGPIE_BUCKET_NAME")
s3_public_url = System.get_env("S3_PUBLIC_URL") || System.get_env("MAGPIE_PUBLIC_URL")
s3_scheme_env = System.get_env("S3_SCHEME") || "https://"

s3_scheme =
  if String.ends_with?(s3_scheme_env, "://"), do: s3_scheme_env, else: s3_scheme_env <> "://"

s3_uri =
  if is_binary(s3_endpoint) and String.contains?(s3_endpoint, "://") do
    URI.parse(s3_endpoint)
  else
    URI.parse("#{s3_scheme}#{s3_endpoint}")
  end

s3_host = s3_uri.host || s3_endpoint

s3_port =
  case System.get_env("S3_PORT") do
    nil -> s3_uri.port || if(s3_scheme == "http://", do: 80, else: 443)
    value -> String.to_integer(value)
  end

local_uploads_dir = Path.join(to_string(:code.priv_dir(:elektrine)), "static/uploads")

s3_configured =
  real_secret?.(s3_access_key_id) and real_secret?.(s3_secret_access_key) and
    present?.(s3_endpoint) and present?.(s3_bucket_name)

if s3_configured do
  config :ex_aws,
    access_key_id: s3_access_key_id,
    secret_access_key: s3_secret_access_key,
    region: "auto",
    json_codec: Jason,
    s3: [
      scheme: s3_scheme,
      host: s3_host,
      region: "auto",
      port: s3_port
    ]

  config :elektrine, :uploads,
    adapter: :s3,
    bucket: s3_bucket_name,
    endpoint: s3_host,
    public_url: s3_public_url,
    max_file_size: 5 * 1024 * 1024,
    max_image_width: 2048,
    max_image_height: 2048
else
  config :elektrine, :uploads,
    adapter: :local,
    uploads_dir: local_uploads_dir,
    max_file_size: 5 * 1024 * 1024,
    max_background_size: 10 * 1024 * 1024,
    max_image_width: 2048,
    max_image_height: 2048
end
