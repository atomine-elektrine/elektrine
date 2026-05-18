defmodule ElektrineWeb.MaidLive do
  use ElektrineWeb, :live_view

  import ElektrineWeb.Components.Platform.ENav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Maid")
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:searched?, false)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"q" => query}, _uri, socket) do
    {:noreply, run_search(socket, query)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply,
       socket
       |> assign(:query, "")
       |> assign(:results, [])
       |> assign(:searched?, false)
       |> assign(:error, nil)
       |> push_patch(to: ~p"/maid")}
    else
      {:noreply, push_patch(socket, to: ~p"/maid?q=#{query}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pb-2 sm:px-6 lg:px-8">
      <.e_nav active_tab="maid" current_user={@current_user} />

      <section class="mx-auto w-full max-w-7xl space-y-6">
        <div class="card panel-card border border-base-300 shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <p class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/45">
              Web Search
            </p>
            <h1 class="card-title mt-1 text-2xl font-bold text-base-content sm:text-3xl">Maid</h1>
            <p class="text-sm text-base-content/70">
              Private, ad-free web search that cleans up results before showing them to you.
            </p>
          </div>
        </div>

        <div class="card panel-card border border-base-300 shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <div class="mb-4 flex items-start justify-between gap-3">
              <div>
                <h2 class="card-title text-lg">Search</h2>
              </div>
            </div>

            <.form for={%{}} as={:search} phx-submit="search">
              <div class="join flex w-full">
                <label class="input input-bordered join-item flex flex-1 items-center gap-2 rounded-r-none">
                  <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-60" />
                  <input
                    id="maid-search-input"
                    type="text"
                    name="q"
                    value={@query}
                    placeholder="Search Maid..."
                    autocomplete="off"
                    class="grow"
                  />
                </label>
                <button class="btn btn-primary join-item rounded-l-none px-6" type="submit">
                  Search
                </button>
              </div>
            </.form>
          </div>
        </div>

        <section :if={@error} class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
          <span>{@error}</span>
        </section>

        <section :if={@searched? && @error == nil} class="space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3 text-sm text-base-content/70">
            <p>
              <span class="font-semibold text-base-content">{length(@results)}</span>
              result{plural_suffix(length(@results))} for
              <span class="font-semibold text-base-content">{@query}</span>
            </p>
          </div>

          <div :if={@results != []} class="card panel-card border border-base-300 shadow-lg">
            <div class="divide-y divide-base-300">
              <article
                :for={result <- @results}
                class="p-4 transition-colors first:rounded-t-[inherit] last:rounded-b-[inherit] hover:bg-base-200/60 sm:p-5"
              >
                <div class="flex flex-col gap-2">
                  <a href={result.url} target="_blank" rel="noopener noreferrer" class="group">
                    <h2 class="text-lg font-semibold text-primary group-hover:underline">
                      {result.title}
                    </h2>
                  </a>
                  <p class="break-all text-xs text-success/80">{result.url}</p>
                  <p :if={result.snippet} class="text-sm leading-6 text-base-content/75">
                    {result.snippet}
                  </p>
                  <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
                    <span class="badge badge-ghost badge-sm">{result.source}</span>
                    <span>score {result.score}</span>
                  </div>
                </div>
              </article>
            </div>
          </div>

          <div
            :if={@results == []}
            class="card panel-card border border-base-300 border-dashed shadow-lg"
          >
            <div class="card-body items-center p-6 text-center sm:p-8">
              <.icon name="hero-magnifying-glass" class="h-10 w-10 text-base-content/30" />
              <h2 class="mt-3 text-lg font-semibold">No results</h2>
            </div>
          </div>
        </section>
      </section>
    </div>
    """
  end

  defp run_search(socket, query) do
    query = String.trim(query || "")

    case Maid.search(query) do
      {:ok, results} ->
        socket
        |> assign(:query, query)
        |> assign(:results, results)
        |> assign(:searched?, true)
        |> assign(:error, nil)

      {:error, :empty_query} ->
        socket
        |> assign(:query, "")
        |> assign(:results, [])
        |> assign(:searched?, false)
        |> assign(:error, nil)

      {:error, _reason} ->
        socket
        |> assign(:query, query)
        |> assign(:results, [])
        |> assign(:searched?, true)
        |> assign(:error, "Maid could not search right now.")
    end
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"
end
