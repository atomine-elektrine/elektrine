defmodule ElektrineWeb.Components.Loaders.Skeleton do
  @moduledoc false
  use Phoenix.Component

  @doc """
  Renders a skeleton loader for a post card.
  """
  def post_skeleton(assigns) do
    ~H"""
    <div class="card glass-card shadow-sm border border-base-300 p-4">
      <!-- Header -->
      <div class="flex items-center gap-3 mb-3">
        <div class="skeleton w-10 h-10 rounded-lg"></div>
        <div class="flex-1">
          <div class="skeleton h-4 w-32 mb-2"></div>
          <div class="skeleton h-3 w-24"></div>
        </div>
      </div>
      <!-- Content -->
      <div class="space-y-2">
        <div class="skeleton h-3 w-full"></div>
        <div class="skeleton h-3 w-5/6"></div>
        <div class="skeleton h-3 w-4/6"></div>
      </div>
      <!-- Actions -->
      <div class="flex gap-4 mt-4">
        <div class="skeleton h-6 w-16"></div>
        <div class="skeleton h-6 w-16"></div>
        <div class="skeleton h-6 w-16"></div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a profile header.
  """
  def profile_skeleton(assigns) do
    ~H"""
    <div class="bg-base-200 border border-base-300 rounded-lg overflow-hidden">
      <!-- Cover -->
      <div class="skeleton h-48 sm:h-60 w-full rounded-none"></div>
      <!-- Profile Info -->
      <div class="px-4 sm:px-6 pb-6">
        <div class="flex items-end justify-between -mt-16 sm:-mt-20 mb-4">
          <div class="skeleton w-24 h-24 sm:w-32 sm:h-32 rounded-full ring-4 ring-base-100"></div>
        </div>
        <div class="skeleton h-6 w-48 mb-2"></div>
        <div class="skeleton h-4 w-32 mb-4"></div>
        <div class="space-y-2">
          <div class="skeleton h-3 w-full"></div>
          <div class="skeleton h-3 w-4/5"></div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a reply/comment.
  """
  def reply_skeleton(assigns) do
    ~H"""
    <div class="pl-4 border-l-2 border-purple-500/60">
      <div class="bg-base-50 rounded-lg p-3">
        <div class="flex items-center gap-2 mb-2">
          <div class="skeleton w-8 h-8 rounded-full"></div>
          <div class="flex-1">
            <div class="skeleton h-3 w-24 mb-1"></div>
            <div class="skeleton h-2 w-16"></div>
          </div>
        </div>
        <div class="space-y-2">
          <div class="skeleton h-3 w-full"></div>
          <div class="skeleton h-3 w-3/4"></div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a user card.
  """
  def user_card_skeleton(assigns) do
    ~H"""
    <div class="flex items-center gap-3 p-3 bg-base-50 rounded-lg">
      <div class="skeleton w-10 h-10 rounded-full"></div>
      <div class="flex-1">
        <div class="skeleton h-4 w-32 mb-1"></div>
        <div class="skeleton h-3 w-24"></div>
      </div>
      <div class="skeleton h-8 w-16"></div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a discussion post.
  """
  def discussion_skeleton(assigns) do
    ~H"""
    <div class="card glass-card shadow-sm border border-base-200">
      <div class="card-body p-4">
        <div class="flex gap-4">
          <!-- Vote column -->
          <div class="flex flex-col items-center gap-2">
            <div class="skeleton w-8 h-6"></div>
            <div class="skeleton w-8 h-6"></div>
          </div>
          <!-- Content -->
          <div class="flex-1">
            <div class="skeleton h-5 w-3/4 mb-3"></div>
            <div class="space-y-2 mb-3">
              <div class="skeleton h-3 w-full"></div>
              <div class="skeleton h-3 w-5/6"></div>
            </div>
            <div class="flex gap-4">
              <div class="skeleton h-4 w-16"></div>
              <div class="skeleton h-4 w-16"></div>
              <div class="skeleton h-4 w-20"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a community card.
  """
  def community_skeleton(assigns) do
    ~H"""
    <div class="card shadow-sm border bg-base-200 border-base-200">
      <div class="card-body p-4">
        <div class="flex items-start gap-3">
          <div class="flex-1">
            <div class="skeleton h-5 w-40 mb-2"></div>
            <div class="skeleton h-3 w-32 mb-3"></div>
            <div class="space-y-2">
              <div class="skeleton h-3 w-full"></div>
              <div class="skeleton h-3 w-4/5"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a gallery image card.
  """
  def gallery_skeleton(assigns) do
    ~H"""
    <div class="relative aspect-square">
      <div class="skeleton w-full h-full rounded-lg"></div>
      <div class="absolute bottom-0 left-0 right-0 p-2">
        <div class="flex items-center gap-2">
          <div class="skeleton w-6 h-6 rounded-full"></div>
          <div class="skeleton h-3 w-20"></div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a skeleton loader for a timeline post (compact).
  """
  def timeline_skeleton(assigns) do
    ~H"""
    <div class="bg-base-200 border border-base-300 rounded-lg p-3">
      <div class="flex gap-3">
        <div class="skeleton w-10 h-10 rounded-full shrink-0"></div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-2">
            <div class="skeleton h-4 w-24"></div>
            <div class="skeleton h-3 w-16"></div>
          </div>
          <div class="space-y-2">
            <div class="skeleton h-3 w-full"></div>
            <div class="skeleton h-3 w-4/5"></div>
          </div>
          <div class="flex gap-4 mt-3">
            <div class="skeleton h-5 w-12"></div>
            <div class="skeleton h-5 w-12"></div>
            <div class="skeleton h-5 w-12"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
