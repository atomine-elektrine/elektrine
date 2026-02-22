defmodule Elektrine.StaticSitesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.StaticSites

  setup do
    user = AccountsFixtures.user_fixture()
    # Clean up test uploads directory
    uploads_dir =
      Application.get_env(:elektrine, :uploads, [])
      |> Keyword.get(:uploads_dir, "tmp/test_uploads")

    File.rm_rf!(uploads_dir)
    File.mkdir_p!(uploads_dir)
    {:ok, user: user, uploads_dir: uploads_dir}
  end

  describe "upload_file/4" do
    test "uploads a valid HTML file", %{user: user} do
      content = "<html><body>Hello</body></html>"
      assert {:ok, file} = StaticSites.upload_file(user, "index.html", content, "text/html")
      assert file.path == "index.html"
      assert file.content_type == "text/html"
      assert file.size == byte_size(content)
    end

    test "uploads a valid CSS file", %{user: user} do
      content = "body { color: red; }"
      assert {:ok, file} = StaticSites.upload_file(user, "style.css", content, "text/css")
      assert file.path == "style.css"
      assert file.content_type == "text/css"
    end

    test "uploads a valid JavaScript file", %{user: user} do
      content = "console.log('hello');"

      assert {:ok, file} =
               StaticSites.upload_file(user, "app.js", content, "application/javascript")

      assert file.path == "app.js"
    end

    test "rejects files with invalid extensions", %{user: user} do
      content = "some content"

      assert {:error, :invalid_file_type} =
               StaticSites.upload_file(user, "file.exe", content, "application/octet-stream")

      assert {:error, :invalid_file_type} =
               StaticSites.upload_file(user, "file.php", content, "text/x-php")
    end

    test "rejects binary content declared as text", %{user: user} do
      # Binary content that's not valid UTF-8
      content = <<0xFF, 0xFE, 0x00, 0x01>>

      assert {:error, :invalid_content} =
               StaticSites.upload_file(user, "index.html", content, "text/html")
    end

    test "validates PNG magic bytes", %{user: user} do
      # Valid PNG header
      valid_png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> "fake png data"
      assert {:ok, _file} = StaticSites.upload_file(user, "image.png", valid_png, "image/png")

      # Invalid PNG (wrong magic bytes)
      invalid_png = "not a png file"

      assert {:error, :invalid_content} =
               StaticSites.upload_file(user, "bad.png", invalid_png, "image/png")
    end

    test "validates JPEG magic bytes", %{user: user} do
      # Valid JPEG header
      valid_jpeg = <<0xFF, 0xD8, 0xFF>> <> "fake jpeg data"
      assert {:ok, _file} = StaticSites.upload_file(user, "image.jpg", valid_jpeg, "image/jpeg")

      # Invalid JPEG
      invalid_jpeg = "not a jpeg"

      assert {:error, :invalid_content} =
               StaticSites.upload_file(user, "bad.jpg", invalid_jpeg, "image/jpeg")
    end

    @tag :slow
    test "enforces file count limit", %{user: user} do
      # Upload 1000 files (the new limit)
      for i <- 1..1000 do
        content = "<html>#{i}</html>"
        assert {:ok, _} = StaticSites.upload_file(user, "page#{i}.html", content, "text/html")
      end

      # 1001st file should fail
      assert {:error, :file_limit_exceeded} =
               StaticSites.upload_file(
                 user,
                 "overflow.html",
                 "<html>overflow</html>",
                 "text/html"
               )
    end

    test "enforces single file size limit", %{user: user} do
      # Single file limit is 50MB
      large_content = String.duplicate("x", 51_000_000)
      # This should fail at validation, not storage limit
      # Note: The validation happens at content level, large text files are allowed
      # but storage limit check will kick in if cumulative
      {:error, _reason} = StaticSites.upload_file(user, "huge.html", large_content, "text/html")
    end
  end

  describe "get_file/2" do
    test "returns uploaded file", %{user: user} do
      content = "<html>test</html>"
      {:ok, _} = StaticSites.upload_file(user, "index.html", content, "text/html")

      file = StaticSites.get_file(user.id, "index.html")
      assert file != nil
      assert file.path == "index.html"
    end

    test "returns nil for non-existent file", %{user: user} do
      assert StaticSites.get_file(user.id, "nonexistent.html") == nil
    end
  end

  describe "get_file_content/1" do
    test "returns file content", %{user: user} do
      content = "<html>my content</html>"
      {:ok, _} = StaticSites.upload_file(user, "index.html", content, "text/html")

      file = StaticSites.get_file(user.id, "index.html")
      assert {:ok, ^content} = StaticSites.get_file_content(file)
    end
  end

  describe "list_files/1" do
    test "lists all files for a user", %{user: user} do
      {:ok, _} = StaticSites.upload_file(user, "index.html", "<html></html>", "text/html")
      {:ok, _} = StaticSites.upload_file(user, "style.css", "body{}", "text/css")

      files = StaticSites.list_files(user.id)
      assert length(files) == 2
      paths = Enum.map(files, & &1.path)
      assert "index.html" in paths
      assert "style.css" in paths
    end
  end

  describe "delete_file/2" do
    test "deletes a file", %{user: user} do
      {:ok, _} = StaticSites.upload_file(user, "index.html", "<html></html>", "text/html")
      assert StaticSites.get_file(user.id, "index.html") != nil

      assert {:ok, _} = StaticSites.delete_file(user.id, "index.html")
      assert StaticSites.get_file(user.id, "index.html") == nil
    end

    test "returns error for non-existent file", %{user: user} do
      assert {:error, :not_found} = StaticSites.delete_file(user.id, "nonexistent.html")
    end
  end

  describe "delete_all_files/1" do
    test "deletes all files for a user", %{user: user} do
      {:ok, _} = StaticSites.upload_file(user, "index.html", "<html></html>", "text/html")
      {:ok, _} = StaticSites.upload_file(user, "style.css", "body{}", "text/css")
      assert length(StaticSites.list_files(user.id)) == 2

      StaticSites.delete_all_files(user.id)
      assert StaticSites.list_files(user.id) == []
    end
  end

  describe "upload_zip/2" do
    test "extracts and uploads files from valid zip", %{user: user} do
      # Create a simple zip file in memory
      zip_files = [
        {~c"index.html", "<html><body>Hello</body></html>"},
        {~c"style.css", "body { color: blue; }"}
      ]

      {:ok, {_name, zip_binary}} = :zip.create(~c"test.zip", zip_files, [:memory])

      assert {:ok, 2} = StaticSites.upload_zip(user, zip_binary)

      files = StaticSites.list_files(user.id)
      paths = Enum.map(files, & &1.path)
      assert "index.html" in paths
      assert "style.css" in paths
    end

    @tag :slow
    test "rejects zip with too many files", %{user: user} do
      # Create zip with 1001 files (new limit is 1000)
      zip_files =
        for i <- 1..1001 do
          {~c"file#{i}.html", "<html>#{i}</html>"}
        end

      {:ok, {_name, zip_binary}} = :zip.create(~c"test.zip", zip_files, [:memory])

      assert {:error, :file_limit_exceeded} = StaticSites.upload_zip(user, zip_binary)
    end

    test "rejects invalid zip data", %{user: user} do
      invalid_zip = "this is not a zip file"
      assert {:error, {:invalid_zip, _}} = StaticSites.upload_zip(user, invalid_zip)
    end

    test "strips common root directory from zip", %{user: user} do
      # Create zip with files in a subdirectory (common when zipping a folder)
      zip_files = [
        {~c"mysite/index.html", "<html>Hello</html>"},
        {~c"mysite/style.css", "body {}"}
      ]

      {:ok, {_name, zip_binary}} = :zip.create(~c"test.zip", zip_files, [:memory])

      assert {:ok, 2} = StaticSites.upload_zip(user, zip_binary)

      files = StaticSites.list_files(user.id)
      paths = Enum.map(files, & &1.path)
      # Should strip the "mysite/" prefix
      assert "index.html" in paths
      assert "style.css" in paths
    end
  end

  describe "zip bomb protection" do
    test "rejects zip with excessive decompression ratio", %{user: user} do
      # Create a highly compressible file (lots of repeated data)
      # This simulates a zip bomb where a small zip decompresses to huge size
      # We create content that compresses very well
      repetitive_content = String.duplicate("AAAAAAAAAA", 1_000_000)

      zip_files = [{~c"bomb.html", repetitive_content}]
      {:ok, {_name, zip_binary}} = :zip.create(~c"bomb.zip", zip_files, [:memory])

      compressed_size = byte_size(zip_binary)
      uncompressed_size = byte_size(repetitive_content)
      ratio = uncompressed_size / compressed_size

      # Only test if we actually achieved high compression
      if ratio > 100 do
        assert {:error, :zip_bomb_detected} = StaticSites.upload_zip(user, zip_binary)
      else
        # If compression ratio is acceptable, it should work
        assert {:ok, _} = StaticSites.upload_zip(user, zip_binary)
      end
    end

    test "accepts zip within storage limit", %{user: user} do
      # Create a zip with content that doesn't compress much (random-like data)
      # Using base64 encoding of random bytes to get text that won't trigger zip bomb detection
      random_content = :crypto.strong_rand_bytes(100_000) |> Base.encode64()

      zip_files = [{~c"data.txt", random_content}]
      {:ok, {_name, zip_binary}} = :zip.create(~c"test.zip", zip_files, [:memory])

      assert {:ok, 1} = StaticSites.upload_zip(user, zip_binary)
    end
  end

  describe "total_storage_used/1" do
    test "calculates total storage used", %{user: user} do
      content1 = "<html>hello</html>"
      content2 = "body { color: red; }"

      {:ok, _} = StaticSites.upload_file(user, "index.html", content1, "text/html")
      {:ok, _} = StaticSites.upload_file(user, "style.css", content2, "text/css")

      expected_size = byte_size(content1) + byte_size(content2)
      assert StaticSites.total_storage_used(user.id) == expected_size
    end
  end

  describe "file_count/1" do
    test "counts files for a user", %{user: user} do
      assert StaticSites.file_count(user.id) == 0

      {:ok, _} = StaticSites.upload_file(user, "index.html", "<html></html>", "text/html")
      assert StaticSites.file_count(user.id) == 1

      {:ok, _} = StaticSites.upload_file(user, "style.css", "body{}", "text/css")
      assert StaticSites.file_count(user.id) == 2
    end
  end

  describe "file editing (update in place)" do
    test "can update existing file content", %{user: user} do
      # Create initial file
      original_content = "<html><body>Original</body></html>"
      {:ok, _file} = StaticSites.upload_file(user, "index.html", original_content, "text/html")

      # Verify original content
      file = StaticSites.get_file(user.id, "index.html")
      {:ok, content} = StaticSites.get_file_content(file)
      assert content == original_content

      # Update the file
      new_content = "<html><body>Updated!</body></html>"
      {:ok, _updated_file} = StaticSites.upload_file(user, "index.html", new_content, "text/html")

      # Verify updated content
      file = StaticSites.get_file(user.id, "index.html")
      {:ok, content} = StaticSites.get_file_content(file)
      assert content == new_content

      # File count should still be 1 (replaced, not added)
      assert StaticSites.file_count(user.id) == 1
    end

    test "updates storage used when file size changes", %{user: user} do
      small_content = "<html>small</html>"
      {:ok, _} = StaticSites.upload_file(user, "index.html", small_content, "text/html")
      small_size = StaticSites.total_storage_used(user.id)

      large_content = "<html>" <> String.duplicate("x", 10_000) <> "</html>"
      {:ok, _} = StaticSites.upload_file(user, "index.html", large_content, "text/html")
      large_size = StaticSites.total_storage_used(user.id)

      assert large_size > small_size
    end
  end

  describe "storage limits" do
    test "1GB storage limit", %{user: user} do
      # Verify the module attribute is set correctly
      # We can't easily test the full 1GB limit, but we can verify large files work
      # Create a 5MB file
      large_content = String.duplicate("x", 5_000_000)
      assert {:ok, _} = StaticSites.upload_file(user, "large.txt", large_content, "text/plain")

      assert StaticSites.total_storage_used(user.id) == 5_000_000
    end

    test "1000 file limit allows many files", %{user: user} do
      # Upload 500 files to verify higher limit works
      for i <- 1..500 do
        content = "<html>#{i}</html>"
        assert {:ok, _} = StaticSites.upload_file(user, "page#{i}.html", content, "text/html")
      end

      assert StaticSites.file_count(user.id) == 500
    end
  end

  describe "content types" do
    test "accepts all valid file types", %{user: user} do
      # HTML
      assert {:ok, _} = StaticSites.upload_file(user, "index.html", "<html></html>", "text/html")
      assert {:ok, _} = StaticSites.upload_file(user, "page.htm", "<html></html>", "text/html")

      # CSS
      assert {:ok, _} = StaticSites.upload_file(user, "style.css", "body{}", "text/css")

      # JavaScript
      assert {:ok, _} =
               StaticSites.upload_file(
                 user,
                 "app.js",
                 "console.log('hi')",
                 "application/javascript"
               )

      # JSON
      assert {:ok, _} =
               StaticSites.upload_file(
                 user,
                 "data.json",
                 "{\"key\":\"value\"}",
                 "application/json"
               )

      # Plain text
      assert {:ok, _} = StaticSites.upload_file(user, "readme.txt", "Hello", "text/plain")

      # Images with valid headers
      valid_png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> "fake png"
      assert {:ok, _} = StaticSites.upload_file(user, "image.png", valid_png, "image/png")

      valid_jpeg = <<0xFF, 0xD8, 0xFF>> <> "fake jpeg"
      assert {:ok, _} = StaticSites.upload_file(user, "photo.jpg", valid_jpeg, "image/jpeg")

      valid_gif = "GIF" <> "fake gif data"
      assert {:ok, _} = StaticSites.upload_file(user, "anim.gif", valid_gif, "image/gif")
    end

    test "rejects invalid file types", %{user: user} do
      assert {:error, :invalid_file_type} =
               StaticSites.upload_file(user, "script.php", "<?php", "text/x-php")

      assert {:error, :invalid_file_type} =
               StaticSites.upload_file(user, "app.exe", "binary", "application/octet-stream")

      assert {:error, :invalid_file_type} =
               StaticSites.upload_file(user, "config.yml", "key: value", "text/yaml")
    end
  end
end
