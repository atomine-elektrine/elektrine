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
  end
end
