defmodule Mix.Tasks.Discussions.DemoPosts do
  @moduledoc """
  Creates demo posts of all types in a community.

  Usage:
    mix discussions.demo_posts [community_name]

  Example:
    mix discussions.demo_posts elektrine
  """
  use Mix.Task

  @shortdoc "Creates demo posts of all types in a community"

  def run(args) do
    Mix.Task.run("app.start")

    community_name = List.first(args) || "elektrine"

    # Get community
    community =
      Elektrine.Repo.get_by(Elektrine.Messaging.Conversation,
        name: community_name,
        type: "community"
      )

    if !community do
      Mix.shell().error("Community '#{community_name}' not found")
      Mix.shell().info("Creating community '#{community_name}'...")

      # Get first user
      user = Elektrine.Repo.all(Elektrine.Accounts.User) |> List.first()

      if !user do
        Mix.shell().error("No users found. Please create a user first.")
        System.halt(1)
      end

      {:ok, community} =
        Elektrine.Messaging.create_group_conversation(
          user.id,
          %{
            name: community_name,
            description: "Demo community for testing post types",
            type: "community",
            is_public: true,
            allow_public_posts: true,
            discussion_style: "forum",
            community_category: "tech"
          },
          []
        )

      Mix.shell().info("Created community: #{community.name}")
    end

    user = Elektrine.Repo.get!(Elektrine.Accounts.User, community.creator_id)

    Mix.shell().info("Creating demo posts in community '#{community.name}'...")

    # 1. TEXT POST
    Mix.shell().info("1. Creating text post...")

    {:ok, text_msg} =
      Elektrine.Messaging.create_text_message(
        community.id,
        user.id,
        "This is a comprehensive discussion about the benefits of functional programming. Elixir brings together the best of both worlds: the productivity of dynamic languages and the robustness of functional programming paradigms.",
        nil,
        skip_broadcast: true
      )

    {:ok, _} =
      text_msg
      |> Elektrine.Messaging.Message.changeset(%{
        title: "Why Functional Programming Matters in 2025",
        post_type: "discussion",
        visibility: "public"
      })
      |> Elektrine.Repo.update()

    Mix.shell().info("   ✓ Text post created")

    # 2. LINK POST
    Mix.shell().info("2. Creating link post...")

    {:ok, link_msg} =
      Elektrine.Messaging.create_text_message(
        community.id,
        user.id,
        "https://elixir-lang.org",
        nil,
        skip_broadcast: true
      )

    {:ok, _} =
      link_msg
      |> Elektrine.Messaging.Message.changeset(%{
        title: "Elixir Programming Language - Official Website",
        post_type: "link",
        primary_url: "https://elixir-lang.org",
        visibility: "public"
      })
      |> Elektrine.Repo.update()

    Mix.shell().info("   ✓ Link post created")

    # 3. IMAGE POST
    Mix.shell().info("3. Creating image post...")

    {:ok, img_msg} =
      Elektrine.Messaging.create_text_message(
        community.id,
        user.id,
        "Check out this Elixir architecture diagram!",
        nil,
        skip_broadcast: true
      )

    {:ok, _} =
      img_msg
      |> Elektrine.Messaging.Message.changeset(%{
        title: "Elixir/Phoenix Architecture Diagram",
        post_type: "discussion",
        message_type: "image",
        # Elixir logo
        media_urls: ["https://avatars.githubusercontent.com/u/1481354?s=200&v=4"],
        visibility: "public"
      })
      |> Elektrine.Repo.update()

    Mix.shell().info("   ✓ Image post created")

    # 4. POLL POST
    Mix.shell().info("4. Creating poll post...")

    {:ok, poll_msg} =
      Elektrine.Messaging.create_text_message(
        community.id,
        user.id,
        # Placeholder content for poll posts
        "Poll",
        nil,
        skip_broadcast: true
      )

    {:ok, poll_msg} =
      poll_msg
      |> Elektrine.Messaging.Message.changeset(%{
        title: "Community Poll: Favorite Web Framework",
        post_type: "poll",
        visibility: "public",
        # Clear placeholder content
        content: ""
      })
      |> Elektrine.Repo.update()

    # Create poll
    closes_at = DateTime.add(DateTime.utc_now(), 7 * 24 * 60 * 60, :second)

    {:ok, poll} =
      Elektrine.Social.create_poll(
        poll_msg.id,
        "What's your favorite web framework for building real-time applications?",
        ["Phoenix/Elixir", "Rails/Ruby", "Django/Python", "Express/Node.js", "ASP.NET Core"],
        closes_at: closes_at,
        allow_multiple: false
      )

    Mix.shell().info("   ✓ Poll post created with #{length(poll.options)} options")

    # 5. MULTI-CHOICE POLL
    Mix.shell().info("5. Creating multi-choice poll post...")

    {:ok, multi_poll_msg} =
      Elektrine.Messaging.create_text_message(
        community.id,
        user.id,
        # Placeholder content for poll posts
        "Poll",
        nil,
        skip_broadcast: true
      )

    {:ok, multi_poll_msg} =
      multi_poll_msg
      |> Elektrine.Messaging.Message.changeset(%{
        title: "What features do you want? (Select all that apply)",
        post_type: "poll",
        visibility: "public",
        # Clear placeholder content
        content: ""
      })
      |> Elektrine.Repo.update()

    {:ok, _multi_poll} =
      Elektrine.Social.create_poll(
        multi_poll_msg.id,
        "Which features would you like to see implemented?",
        [
          "Dark theme toggle",
          "Mobile notifications",
          "Video calls",
          "Screen sharing",
          "File sharing",
          "Code snippets"
        ],
        # Never closes
        closes_at: nil,
        allow_multiple: true
      )

    Mix.shell().info("   ✓ Multi-choice poll created (never expires)")

    Mix.shell().info("")
    Mix.shell().info("✅ Successfully created 5 demo posts:")
    Mix.shell().info("   • 1 Text post")
    Mix.shell().info("   • 1 Link post")
    Mix.shell().info("   • 1 Image post")
    Mix.shell().info("   • 2 Poll posts (single + multi-choice)")
    Mix.shell().info("")
    Mix.shell().info("Visit: http://localhost:4000/discussions/#{community.name}")
    Mix.shell().info("")
  end
end
