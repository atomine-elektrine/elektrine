defmodule KairoTest do
  use Kairo.DataCase, async: true

  import Kairo.AccountsFixtures

  describe "projects" do
    test "create_project/2 creates a user-owned project with a slug" do
      user = user_fixture()

      assert {:ok, project} =
               Kairo.create_project(user, %{
                 "name" => "Agent Memory",
                 "description" => "Research feed"
               })

      assert project.user_id == user.id
      assert project.slug == "agent-memory"
      assert project.status == "active"
      assert project.autonomy_level == 1
    end
  end

  describe "sources" do
    test "create_source/2 ingests source payloads into the optional inbox" do
      user = user_fixture()

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "markdown",
                 "title" => "Notebook",
                 "content" => "# Kairo",
                 "tags" => "llm, research"
               })

      assert source.user_id == user.id
      assert source.project_id == nil
      assert source.status == "received"
      assert source.tags == ["llm", "research"]
      assert is_binary(source.raw_hash)
      assert source.ingested_at
    end

    test "create_source/2 enforces project ownership" do
      owner = user_fixture()
      other_user = user_fixture()
      {:ok, project} = Kairo.create_project(owner, %{"name" => "Private"})

      assert {:error, :project_not_found} =
               Kairo.create_source(other_user, %{
                 "project_id" => project.id,
                 "source_type" => "url",
                 "url" => "https://example.com"
               })
    end

    test "create_source/2 stores an encrypted source zero-knowledge" do
      user = user_fixture()

      payload = %{
        "version" => 2,
        "algorithm" => "AES-GCM",
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "title" => "Private note",
                 "content" => "this should never be stored",
                 "encrypted" => true,
                 "encrypted_content" => payload
               })

      # Plaintext is dropped; only the ciphertext envelope is kept.
      assert source.encrypted
      assert source.content == nil
      assert source.encrypted_content["ciphertext"] == payload["ciphertext"]
      # Encrypted rows are parked at "stored" (no server processing) and the
      # server computes no content hash it could use to confirm the plaintext.
      assert source.status == "stored"
      assert source.raw_hash == nil
    end

    test "create_source/2 encrypts plaintext content at rest" do
      user = user_fixture()

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "markdown",
                 "title" => "Server note",
                 "content" => "at-rest secret body"
               })

      # Reads transparently return the plaintext content...
      assert source.content == "at-rest secret body"
      assert Kairo.get_source(user, source.id).content == "at-rest secret body"

      # ...but the stored row holds a ciphertext map, not plaintext, and is not
      # flagged as a zero-knowledge source.
      row = Elektrine.Repo.get!(Kairo.Source, source.id)
      assert is_nil(row.content)
      assert is_map(row.content_encrypted)
      refute row.encrypted
      assert is_nil(row.encrypted_content)
    end

    test "create_source/2 rejects an encrypted source without a ciphertext payload" do
      user = user_fixture()

      assert {:error, changeset} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "encrypted" => true
               })

      assert %{encrypted_content: _} = errors_on(changeset)
    end
  end
end
