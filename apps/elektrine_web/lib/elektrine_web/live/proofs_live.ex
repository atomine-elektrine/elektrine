defmodule ElektrineWeb.ProofsLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts.Capabilities
  alias Elektrine.Platform.ENav

  @proof_kinds [
    {"DNS TXT", "dns"},
    {"Web page", "web"},
    {"Social/profile page", "social"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: Elektrine.Paths.login_path())}

      user ->
        {:ok,
         socket
         |> assign(:page_title, "Proofs")
         |> assign(:proof_kinds, @proof_kinds)
         |> assign(:proof_form, default_proof_form())
         |> assign(:negative_form, %{"subject" => ""})
         |> load_proofs(user.id)}
    end
  end

  @impl true
  def handle_event("change_kind", %{"proof-kind" => kind}, socket) do
    kind = normalize_absolute_proof_kind(kind)

    form =
      socket.assigns.proof_form
      |> Map.put("kind", kind)
      |> Map.put("proof_mode", default_mode(kind))
      |> Map.put("target", "")
      |> Map.put("subject", "")
      |> Map.put("evidence_url", "")

    {:noreply, assign(socket, :proof_form, form)}
  end

  def handle_event("change_kind", %{"proof" => params}, socket) do
    form =
      socket.assigns.proof_form
      |> Map.merge(params)
      |> Map.update("kind", "dns", &normalize_absolute_proof_kind/1)

    {:noreply,
     assign(socket, :proof_form, Map.put(form, "proof_mode", default_mode(form["kind"])))}
  end

  def handle_event("create_proof", %{"proof" => params}, socket) do
    user = socket.assigns.current_user

    case create_proof(user, normalize_proof_params(params)) do
      {:ok, proof} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proof created. Publish the statement, then use Check now.")
         |> assign(:proof_form, default_proof_form())
         |> assign(:last_created_proof, proof)
         |> load_proofs(user.id)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, proof_error(changeset))}
    end
  end

  def handle_event("create_negative_assertion", %{"assertion" => params}, socket) do
    user = socket.assigns.current_user

    case create_negative_assertion(user, %{
           kind: "social",
           subject: Map.get(params, "subject", "")
         }) do
      {:ok, proof} ->
        {:noreply,
         socket
         |> put_flash(:info, "Assertion added.")
         |> assign(:negative_form, %{"subject" => ""})
         |> assign(:last_created_proof, proof)
         |> load_proofs(user.id)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, proof_error(changeset))}
    end
  end

  def handle_event("check_proof", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {proof_id, ""} <- Integer.parse(id),
         {:ok, proof} <- get_owned_proof(user.id, proof_id) do
      case check_proof(proof) do
        {:ok, _verified} ->
          {:noreply,
           socket
           |> put_flash(:info, "Proof verified.")
           |> load_proofs(user.id)}

        {:error, {:not_found, _updated_proof}} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Challenge was not found yet. Check the instructions and try again."
           )
           |> load_proofs(user.id)}

        {:error, :manual_review_required} ->
          {:noreply, put_flash(socket, :info, "This proof requires manual review.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not check proof: #{format_reason(reason)}")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Proof not found.")}
    end
  end

  def handle_event("delete_proof", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {proof_id, ""} <- Integer.parse(id),
         {:ok, proof} <- get_owned_proof(user.id, proof_id),
         {:ok, _deleted} <- delete_proof(proof) do
      {:noreply,
       socket
       |> put_flash(:info, "Proof deleted.")
       |> load_proofs(user.id)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete proof.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.account_page
      title="Proofs"
      subtitle="Verify control of a domain or web page."
      sidebar_link="proofs"
      nav_tab="proofs"
      current_user={@current_user}
      badge_counts={@e_nav_badge_counts}
      show_header={false}
    >
      <div :if={!@atomine_available} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>
          Proofs are not available until Atomine is loaded. Restart the server if this was just enabled.
        </span>
      </div>

      <div :if={@last_created_proof} class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <div>
          <p class="font-semibold">Proof created</p>
          <p class="text-sm">
            Publish this signed proof statement, then use Check now from the proof list.
          </p>
          <p class="break-all font-mono text-sm">{@last_created_proof.challenge}</p>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div class="space-y-6">
          <div class="card panel-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <h2 class="card-title text-lg mb-2">Proofs</h2>
                  <p class="text-sm text-base-content/70">
                    Verify control of a domain or web page.
                  </p>
                </div>

                <span class="badge badge-outline badge-sm shrink-0 text-[10px] uppercase tracking-[0.16em] text-base-content/60">
                  Powered by Atomine
                </span>
              </div>

              <div class="alert alert-info mt-2">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span>{instruction_body(@proof_form["kind"])}</span>
              </div>

              <.form
                for={%{}}
                as={:proof}
                phx-change="change_kind"
                phx-submit="create_proof"
                class="mt-4 space-y-5"
              >
                <.input
                  id="proof-kind"
                  type="select"
                  name="proof[kind]"
                  label="Proof type"
                  value={@proof_form["kind"]}
                  options={@proof_kinds}
                />

                <p class="text-sm text-base-content/70">
                  {proof_kind_description(@proof_form["kind"])}
                </p>

                <.input
                  id="proof-target"
                  type={target_input_type(@proof_form["kind"])}
                  name="proof[target]"
                  label={target_label(@proof_form["kind"])}
                  value={@proof_form["target"] || @proof_form["subject"]}
                  placeholder={target_placeholder(@proof_form["kind"])}
                  required
                />

                <.input
                  :if={show_evidence_url?(@proof_form["kind"])}
                  id="proof-evidence-url"
                  type="url"
                  name="proof[evidence_url]"
                  label="Evidence URL"
                  value={@proof_form["evidence_url"]}
                  placeholder="https://example.com/proof"
                />

                <.input
                  id="proof-mode"
                  type="select"
                  name="proof[proof_mode]"
                  label="Mode"
                  value={@proof_form["proof_mode"]}
                  options={[{"Snapshot", "snapshot"}, {"Live re-checkable", "live"}]}
                />

                <button class="btn btn-primary w-full sm:w-auto" type="submit">Create proof</button>
              </.form>
            </div>
          </div>

          <div class="card panel-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
                <div>
                  <h2 class="card-title text-lg mb-2">Your Proofs</h2>
                  <p class="text-sm text-base-content/70">
                    Pending proofs need the signed statement to be published before they can be verified.
                  </p>
                </div>
                <span class="text-sm text-base-content/60">{length(@proofs)} total</span>
              </div>

              <%= if Enum.empty?(@proofs) do %>
                <div class="rounded-lg border border-dashed border-base-300 bg-base-200/30 p-6">
                  <p class="font-semibold">No proofs yet</p>
                  <p class="mt-1 text-sm text-base-content/60">
                    Create a DNS or web proof above.
                  </p>
                </div>
              <% else %>
                <div class="divide-y divide-base-300 overflow-hidden rounded-lg border border-base-300 bg-base-100">
                  <%= for proof <- @proofs do %>
                    <div class="p-4">
                      <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                        <div class="min-w-0 space-y-2">
                          <div class="flex flex-wrap items-center gap-2">
                            <span class="badge badge-outline">{proof_kind_label(proof.kind)}</span>
                            <span class={status_badge_class(proof.status)}>
                              {String.capitalize(proof.status)}
                            </span>
                            <span :if={proof.claim_type == "negative"} class="badge badge-neutral">
                              Negative
                            </span>
                          </div>
                          <p class="break-all font-medium">{claim_subject_label(proof)}</p>
                          <p :if={proof.evidence_url} class="break-all text-sm text-base-content/70">
                            <a href={proof.evidence_url} target="_blank" class="link link-primary">
                              {proof.evidence_url}
                            </a>
                          </p>
                        </div>
                        <div class="flex items-center gap-3 text-sm sm:block sm:text-right">
                          <p class="font-semibold">{proof.score_weight} pts</p>
                          <p class="text-base-content/60">{proof.verification_method}</p>
                          <button
                            :if={checkable_proof?(proof)}
                            type="button"
                            phx-click="check_proof"
                            phx-value-id={proof.id}
                            class="btn btn-primary btn-xs mt-2"
                          >
                            Check now
                          </button>
                          <button
                            type="button"
                            phx-click="delete_proof"
                            phx-value-id={proof.id}
                            data-confirm="Delete this proof?"
                            class="btn btn-ghost btn-xs mt-2 text-error"
                          >
                            Delete
                          </button>
                        </div>
                      </div>

                      <details
                        :if={proof.status != "verified"}
                        class="mt-4 rounded-lg bg-base-200/60 px-4 py-3"
                      >
                        <summary class="cursor-pointer text-sm font-medium">Proof statement</summary>
                        <p class="mt-2 break-all font-mono text-xs text-base-content/80">
                          {proof.challenge}
                        </p>
                      </details>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <div class="space-y-6">
          <div class="card panel-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <div class="flex items-baseline justify-between gap-3">
                <h2 class="card-title text-lg">Account</h2>
                <span class="text-sm font-semibold">TL{@current_user.trust_level || 0}</span>
              </div>

              <dl class="mt-4 divide-y divide-base-300 text-sm">
                <div :if={@credits_available} class="flex items-center justify-between gap-4 pb-3">
                  <dt>
                    <p class="font-medium">Atomine Credits</p>
                    <p class="mt-1 text-xs text-base-content/60">Spendable action capacity.</p>
                  </dt>
                  <dd class="text-3xl font-semibold leading-none">
                    {credit_balance(@credit_rows, "atomine_credit")}
                  </dd>
                </div>
                <div class="flex items-center justify-between gap-3 py-3">
                  <dt class="text-base-content/70">Proof score</dt>
                  <dd class="font-medium">{@breakdown.score}</dd>
                </div>
                <div class="flex items-center justify-between gap-3 py-3">
                  <dt class="text-base-content/70">Verified proofs</dt>
                  <dd class="font-medium">{proof_status_count(@proofs, "verified")}</dd>
                </div>
                <div class="flex items-center justify-between gap-3 py-3">
                  <dt class="text-base-content/70">Pending proofs</dt>
                  <dd class="font-medium">{proof_status_count(@proofs, "pending")}</dd>
                </div>
              </dl>

              <p class="text-xs text-base-content/60">{level_label(@breakdown.level)}</p>

              <details
                :if={@credits_available && @credit_earning_paths != []}
                class="mt-5 border-t border-base-300 pt-4"
              >
                <summary class="cursor-pointer text-sm font-medium">How to earn credits</summary>
                <div class="mt-3 space-y-2 text-xs text-base-content/70">
                  <p :for={path <- active_earning_paths(@credit_earning_paths)}>
                    <span class="font-medium text-base-content">{path.label}:</span> {path.reward}
                  </p>
                  <p :if={planned_earning_path_labels(@credit_earning_paths) != ""}>
                    Planned: {planned_earning_path_labels(@credit_earning_paths)}.
                  </p>
                </div>
              </details>

              <details
                :if={@credits_available && @credit_action_prices != []}
                class="mt-4 border-t border-base-300 pt-4"
              >
                <summary class="cursor-pointer text-sm font-medium">Pricing</summary>
                <dl class="mt-3 divide-y divide-base-300 text-sm">
                  <div
                    :for={price <- @credit_action_prices}
                    class="flex items-start justify-between gap-4 py-2 first:pt-0 last:pb-0"
                  >
                    <dt>{price.label}</dt>
                    <dd class="text-right text-xs text-base-content/70">
                      {compact_credit_price(price)}
                    </dd>
                  </div>
                </dl>
                <p class="mt-3 text-xs text-base-content/60">
                  {credit_gate_summary(@credit_action_prices)}
                </p>
              </details>

              <details
                :if={@credits_available && visible_restricted_credit_rows(@credit_rows) != []}
                class="mt-4 border-t border-base-300 pt-4"
              >
                <summary class="cursor-pointer text-sm font-medium">Action-specific credits</summary>
                <dl class="mt-3 divide-y divide-base-300 text-sm">
                  <div
                    :for={row <- visible_restricted_credit_rows(@credit_rows)}
                    class="flex items-center justify-between gap-3 py-2 first:pt-0 last:pb-0"
                  >
                    <dt class="text-base-content/70">{row.label}</dt>
                    <dd class="font-medium">{row.balance}</dd>
                  </div>
                </dl>
              </details>

              <div class="mt-5 border-t border-base-300 pt-5">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h3 class="font-semibold text-sm">GitHub</h3>
                    <p class="mt-1 text-xs text-base-content/60">
                      Adds an account signal; DNS and web proofs stay separate.
                    </p>
                  </div>
                  <.link
                    navigate={~p"/account/connections/github/start?return_to=/account/proofs"}
                    class={[
                      "btn btn-outline btn-sm shrink-0",
                      !github_oauth_configured?() && "btn-disabled"
                    ]}
                  >
                    Connect
                  </.link>
                </div>
                <p :if={!github_oauth_configured?()} class="mt-2 text-xs text-base-content/60">
                  GitHub OAuth is not configured on this server.
                </p>
              </div>

              <details class="mt-5 border-t border-base-300 pt-5">
                <summary class="cursor-pointer text-sm font-medium">Negative assertion</summary>
                <p class="mt-2 text-xs text-base-content/60">
                  Self-declare a social account you do not use. It does not increase score.
                </p>

                <.form
                  for={%{}}
                  as={:assertion}
                  phx-submit="create_negative_assertion"
                  class="mt-3 space-y-3"
                >
                  <.input
                    id="negative-assertion-subject"
                    type="text"
                    name="assertion[subject]"
                    label="Subject"
                    value={@negative_form["subject"]}
                    placeholder="twitter.com/your-old-handle"
                    required
                  />

                  <button class="btn btn-secondary btn-sm w-full" type="submit">Add assertion</button>
                </.form>
              </details>
            </div>
          </div>
        </div>
      </div>
    </.account_page>
    """
  end

  defp load_proofs(socket, user_id) do
    {proofs, atomine_available} = proof_data(user_id)
    capability_snapshot = Capabilities.snapshot(socket.assigns.current_user)
    credits = capability_snapshot.credits

    socket
    |> assign(:proofs, proofs)
    |> assign(:breakdown, capability_snapshot.reputation.breakdown)
    |> assign(:capability_snapshot, capability_snapshot)
    |> assign(:e_nav_badge_counts, ENav.notification_badge_counts(socket.assigns.current_user))
    |> assign(:atomine_available, atomine_available)
    |> assign(:credit_rows, credits.rows)
    |> assign(:credit_action_prices, credits.action_prices)
    |> assign(:credit_earning_paths, credits.earning_paths)
    |> assign(:credits_available, Map.fetch!(credits, :available?))
    |> assign_new(:last_created_proof, fn -> nil end)
  end

  defp get_owned_proof(user_id, proof_id) do
    case personhood_module() do
      {:ok, personhood} ->
        proof = personhood.get_proof!(proof_id)

        if proof.user_id == user_id do
          {:ok, proof}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :atomine_unavailable}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp check_proof(proof) do
    case personhood_module() do
      {:ok, personhood} -> personhood.check_proof(proof)
      :error -> {:error, :atomine_unavailable}
    end
  end

  defp delete_proof(proof) do
    case personhood_module() do
      {:ok, personhood} -> personhood.delete_proof(proof)
      :error -> {:error, :atomine_unavailable}
    end
  end

  defp proof_data(user_id) do
    case personhood_module() do
      {:ok, personhood} ->
        {personhood.list_proofs(user_id), true}

      :error ->
        {[], false}
    end
  end

  defp create_proof(user, params) do
    case personhood_module() do
      {:ok, personhood} -> personhood.create_proof(user, params)
      :error -> {:error, :atomine_unavailable}
    end
  end

  defp create_negative_assertion(user, params) do
    case personhood_module() do
      {:ok, personhood} -> personhood.create_negative_assertion(user, params)
      :error -> {:error, :atomine_unavailable}
    end
  end

  defp personhood_module do
    if Code.ensure_loaded?(Atomine.Personhood) do
      {:ok, Atomine.Personhood}
    else
      :error
    end
  end

  defp default_proof_form do
    %{
      "kind" => "dns",
      "target" => "",
      "subject" => "",
      "evidence_url" => "",
      "proof_mode" => "live"
    }
  end

  defp normalize_proof_params(params) do
    kind = Map.get(params, "kind", "dns") |> normalize_absolute_proof_kind()
    target = Map.get(params, "target") || Map.get(params, "subject", "")
    evidence_url = normalized_evidence_url(kind, target, Map.get(params, "evidence_url", ""))

    %{
      kind: kind,
      subject: target,
      evidence_url: evidence_url,
      proof_mode: Map.get(params, "proof_mode", default_mode(kind))
    }
  end

  defp normalized_evidence_url(kind, target, evidence_url) when kind in ["web", "social"] do
    target || evidence_url
  end

  defp normalized_evidence_url("dns", _target, _evidence_url), do: nil

  defp normalized_evidence_url(_kind, _target, ""), do: nil
  defp normalized_evidence_url(_kind, _target, evidence_url), do: evidence_url

  defp normalize_absolute_proof_kind(kind) when kind in ["dns", "web", "social"], do: kind
  defp normalize_absolute_proof_kind(_), do: "dns"

  defp default_mode(kind) when kind in ["web", "dns", "social"], do: "live"
  defp default_mode(_), do: "snapshot"

  defp target_label("dns"), do: "Domain"
  defp target_label("web"), do: "Page URL"
  defp target_label("social"), do: "Profile or public page URL"
  defp target_label("manual"), do: "Subject"
  defp target_label(_), do: "Subject"

  defp target_placeholder("dns"), do: "example.com"
  defp target_placeholder("social"), do: "https://social.example/@you"
  defp target_placeholder("manual"), do: "Manual review request"
  defp target_placeholder(_), do: "https://example.com/about"

  defp target_input_type("dns"), do: "text"
  defp target_input_type("manual"), do: "text"
  defp target_input_type(_), do: "url"

  defp show_evidence_url?("manual"), do: true
  defp show_evidence_url?(_), do: false

  defp instruction_body("dns") do
    "Enter a domain you control. After creating the proof, add a TXT record at _atomine.your-domain containing the exact signed statement."
  end

  defp instruction_body("web") do
    "Enter a public page you control. After creating the proof, place the exact signed statement in the public page text."
  end

  defp instruction_body("social") do
    "Enter a stable public profile or account page you control. After creating the proof, publish the signed statement in a bio, about section, pinned post, or public GitHub gist, then use Check now."
  end

  defp instruction_body("manual") do
    "Use this for proofs that need a human reviewer. Include a clear subject and evidence URL."
  end

  defp instruction_body(_), do: "Create a proof to receive a signed statement."

  defp proof_kind_description("dns") do
    "DNS check: Elektrine queries the domain and must find the exact signed statement in TXT."
  end

  defp proof_kind_description("web") do
    "Web check: Elektrine fetches the URL and must find the exact signed statement in the page."
  end

  defp proof_kind_description("social") do
    "Best for accounts with public, stable profile pages. GitHub gists are auto-checkable; other profile pages work when the statement is visible in public page text."
  end

  defp proof_kind_description("manual") do
    "Use this for durable evidence that cannot be checked automatically, such as an account on a platform that hides profile text from crawlers."
  end

  defp proof_kind_description(_), do: "Choose where this proof should live."

  defp credit_balance(rows, credit_type) do
    case Enum.find(rows, &(&1.type == credit_type)) do
      %{balance: balance} -> balance
      _ -> 0
    end
  end

  defp visible_restricted_credit_rows(rows) do
    rows
    |> Enum.reject(&(&1.type == "atomine_credit"))
    |> Enum.filter(&(&1.balance > 0))
  end

  defp compact_credit_price(price) do
    "#{credit_amount_label(price.atomine_cost, "atomine_credit")} / #{credit_amount_label(price.restricted_cost, price.restricted_credit_type)}"
  end

  defp credit_amount_label(amount, credit_type) do
    "#{amount} #{credit_unit_label(credit_type)}#{plural_suffix(amount)}"
  end

  defp credit_label("atomine_credit"), do: "Atomine Credits"
  defp credit_label("dm_credit"), do: "DM Credits"
  defp credit_label("email_credit"), do: "Email Credits"
  defp credit_label("link_credit"), do: "Link Credits"
  defp credit_label("signup_credit"), do: "Signup Credits"
  defp credit_label("api_credit"), do: "API Credits"
  defp credit_label("invite_credit"), do: "Invite Credits"
  defp credit_label(value), do: titleize_credit_type(value)

  defp credit_unit_label(credit_type) do
    credit_type
    |> credit_label()
    |> String.trim_trailing("s")
  end

  defp titleize_credit_type(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"

  defp credit_gate_summary(prices) do
    if Enum.any?(prices, & &1.gate_enabled) do
      "Some gates are enabled. TL1+ and admins bypass current priced gates."
    else
      "Gates are currently off."
    end
  end

  defp active_earning_paths(paths), do: Enum.filter(paths, &(&1.status == :active))

  defp planned_earning_path_labels(paths) do
    paths
    |> Enum.filter(&(&1.status != :active))
    |> Enum.map_join(", ", &String.replace_prefix(&1.label, "Proof of ", ""))
  end

  defp checkable_proof?(proof) do
    proof.claim_type == "positive" and proof.status in ["pending", "verified"] and
      proof.verification_method in ["dns", "page", "github_gist"]
  end

  defp github_oauth_configured? do
    present_env?("GITHUB_OAUTH_CLIENT_ID") and present_env?("GITHUB_OAUTH_CLIENT_SECRET")
  end

  defp present_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp level_label(:high), do: "Strong verified control"
  defp level_label(:medium), do: "Some verified control"
  defp level_label(:low), do: "Limited verified control"
  defp level_label(_), do: "No verified control"

  defp proof_status_count(proofs, status) when is_list(proofs) do
    Enum.count(proofs, &(&1.status == status))
  end

  defp proof_status_count(_, _), do: 0

  defp proof_kind_label("dns"), do: "DNS TXT"
  defp proof_kind_label("web"), do: "Web page"
  defp proof_kind_label("social"), do: "Social/profile page"
  defp proof_kind_label("manual"), do: "Manual review"
  defp proof_kind_label(kind) when is_binary(kind), do: String.capitalize(kind)
  defp proof_kind_label(_), do: "Proof"

  defp claim_subject_label(%{verification_method: "oauth", metadata: metadata, subject: subject}) do
    provider = Map.get(metadata || %{}, "provider")
    username = Map.get(metadata || %{}, "username")

    if is_binary(provider) and is_binary(username) and username != "" do
      "#{String.capitalize(provider)}: #{username}"
    else
      subject
    end
  end

  defp claim_subject_label(%{subject: subject}), do: subject

  defp status_badge_class("verified"), do: "badge badge-success"
  defp status_badge_class("pending"), do: "badge badge-warning"
  defp status_badge_class("asserted"), do: "badge badge-info"
  defp status_badge_class("rejected"), do: "badge badge-error"
  defp status_badge_class("revoked"), do: "badge badge-neutral"
  defp status_badge_class(_), do: "badge badge-outline"

  defp proof_error(changeset) do
    case changeset do
      :atomine_unavailable ->
        "Proofs are not available until Atomine is loaded. Restart the server if this was just enabled."

      %{errors: errors} ->
        errors
        |> Enum.map_join(", ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
        |> case do
          "" -> "Could not create proof."
          message -> "Could not create proof: #{message}"
        end
    end
  end

  defp format_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_reason(reason), do: inspect(reason)
end
