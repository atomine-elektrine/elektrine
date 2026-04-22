defmodule Elektrine.ActivityPub.Visibility do
  @moduledoc false

  @public_audience_uris MapSet.new([
                          "Public",
                          "as:Public",
                          "https://www.w3.org/ns/activitystreams#Public"
                        ])

  def visibility(object, opts \\ [])

  def visibility(object, opts) when is_map(object) do
    to = List.wrap(object["to"])
    cc = List.wrap(object["cc"])

    cond do
      Enum.any?(to, &public_audience?/1) ->
        "public"

      Enum.any?(cc, &public_audience?/1) ->
        "unlisted"

      Keyword.get(opts, :assume_public_reply_without_audience, false) and
        is_binary(object["inReplyTo"]) and to == [] and cc == [] ->
        "public"

      true ->
        "followers"
    end
  end

  def visibility(_object, _opts), do: "followers"

  def public?(object, opts \\ []) do
    visibility(object, opts) == "public"
  end

  def publicly_addressed?(object) when is_map(object) do
    object
    |> audience_refs()
    |> Enum.any?(&public_audience?/1)
  end

  def publicly_addressed?(_object), do: false

  def public_audience?(value) when is_binary(value) do
    MapSet.member?(@public_audience_uris, String.trim(value))
  end

  def public_audience?(_value), do: false

  def audience_refs(object) when is_map(object) do
    List.wrap(object["to"]) ++ List.wrap(object["cc"])
  end

  def audience_refs(_object), do: []
end
