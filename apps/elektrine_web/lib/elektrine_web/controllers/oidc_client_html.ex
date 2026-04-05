defmodule ElektrineWeb.OIDCClientHTML do
  use ElektrineWeb, :html

  attr :changeset, :any, required: true
  attr :action, :string, required: true
  attr :method, :string, default: nil
  attr :submit_label, :string, required: true
  attr :cancel_path, :string, required: true
  attr :selected_scopes, :list, default: []
  attr :scope_options, :list, default: []
  attr :redirect_uri_text, :string, default: nil

  def client_form(assigns) do
    ~H"""
    <.simple_form
      :let={f}
      for={@changeset}
      action={@action}
      method={@method}
      bare={true}
      class="space-y-6"
    >
      <div class="space-y-6">
        <section class="rounded-2xl border border-base-300/60 bg-base-200/40 p-4 sm:p-5">
          <div class="space-y-1">
            <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/50">
              Client Details
            </p>
            <p class="text-sm text-base-content/70">
              Choose how this app appears during sign-in and where users can learn more about it.
            </p>
          </div>

          <div class="mt-5 grid gap-4 sm:grid-cols-2">
            <.input field={f[:client_name]} type="text" label="Client name" required />
            <.input
              field={f[:website]}
              type="url"
              label="Website"
              placeholder="https://example.com"
            />
          </div>
        </section>

        <section class="rounded-2xl border border-base-300/60 bg-base-200/40 p-4 sm:p-5">
          <div class="space-y-1">
            <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/50">
              Redirect URIs
            </p>
            <p class="text-sm text-base-content/70">
              Enter one exact callback URI per line. Each value must match the redirect your app sends during OAuth.
            </p>
          </div>

          <div class="mt-5 space-y-3">
            <label for={f[:redirect_uris].id} class="block text-sm font-medium text-base-content">
              Redirect URIs
            </label>

            <textarea
              id={f[:redirect_uris].id}
              name={f[:redirect_uris].name}
              required
              class="textarea textarea-bordered min-h-[10rem] w-full font-mono text-sm leading-6"
              placeholder="https://example.com/auth/callback&#10;http://localhost:3000/auth/callback"
            >{Phoenix.HTML.Form.normalize_value("textarea", @redirect_uri_text || f[:redirect_uris].value)}</textarea>

            <p class="text-xs leading-5 text-base-content/60">
              Local development URLs are allowed. Include the full scheme, host, port, and path.
            </p>

            <div class="rounded-xl border border-dashed border-base-300/70 bg-base-100/70 px-4 py-3 text-xs text-base-content/65">
              Example: `http://localhost:4000/auth/callback`
            </div>

            <.error :for={msg <- Keyword.get_values(@changeset.errors, :redirect_uris)}>
              {translate_error(msg)}
            </.error>
          </div>
        </section>

        <section class="rounded-2xl border border-base-300/60 bg-base-200/40 p-4 sm:p-5">
          <div class="space-y-1">
            <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/50">
              Permissions
            </p>
            <p class="text-sm text-base-content/70">
              Limit this client to the minimum scopes it needs.
            </p>
          </div>

          <div class="mt-5 grid gap-3 sm:grid-cols-2">
            <label
              :for={scope <- @scope_options}
              class="flex items-start gap-3 rounded-2xl border border-base-300/70 bg-base-100/70 px-4 py-3 transition-colors hover:border-base-300 hover:bg-base-100"
            >
              <input
                type="checkbox"
                name="app[scopes][]"
                value={scope.value}
                checked={scope.value in @selected_scopes}
                class="checkbox checkbox-sm mt-0.5"
              />

              <span class="min-w-0 space-y-1">
                <span class="block text-sm font-medium text-base-content">{scope.value}</span>
                <span class="block text-xs leading-5 text-base-content/65">{scope.description}</span>
              </span>
            </label>
          </div>

          <p class="mt-3 text-xs text-base-content/60">
            Keep `openid` enabled if the client needs OpenID Connect identity tokens.
          </p>
        </section>
      </div>

      <:actions>
        <div class="flex w-full flex-col gap-3 border-t border-base-300/60 pt-6 sm:flex-row sm:justify-end">
          <.link href={@cancel_path} class="btn btn-ghost rounded-full">
            Cancel
          </.link>
          <.button class="rounded-full">{@submit_label}</.button>
        </div>
      </:actions>
    </.simple_form>
    """
  end

  embed_templates "oidc_client_html/*"
end
