defmodule ElektrineWeb.PageLive.Privacy do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  @sections [
    %{
      title: "Information We Collect",
      blocks: [
        %{
          subtitle: "Account and Profile Data",
          paras: [],
          items: [
            "Account identifiers such as username, mailbox address, login credentials, and recovery or security settings.",
            "Profile information you choose to publish, such as display name, avatar, bio, links, and public posts.",
            "Preferences such as locale, notification settings, privacy settings, and enabled product features."
          ]
        },
        %{
          subtitle: "Content You Store or Send",
          paras: [],
          items: [
            "Email messages, drafts, sent-mail copies, folders, labels, contacts, aliases, attachments, and filtering preferences.",
            "Social posts, chats, notes, files, nerve metadata, and other content you create or upload.",
            "Operational metadata needed to provide these services, such as message IDs, timestamps, delivery status, mailbox IDs, thread IDs, flags, and storage usage."
          ]
        },
        %{
          subtitle: "Information Collected Automatically",
          paras: [],
          items: [
            "IP addresses, user agents, device/browser information, request timestamps, and session identifiers.",
            "Security and abuse-prevention data such as login attempts, rate-limit events, SMTP/IMAP/POP connection events, and spam or malware signals.",
            "Service logs and metrics used to operate, debug, secure, and improve Elektrine."
          ]
        }
      ]
    },
    %{
      title: "Email Privacy and Encryption",
      blocks: [
        %{
          subtitle: nil,
          paras: [
            "Email uses open internet protocols. Elektrine can protect local storage, but normal SMTP delivery still exposes some information to mail infrastructure."
          ],
          items: []
        },
        %{
          subtitle: "Stored Mail",
          paras: [],
          items: [
            "By default, message bodies are encrypted at rest for the account using server-side application encryption, while some metadata remains available to the server for mailbox operation.",
            "If private mailbox storage is enabled, message subject, body, attachments, sender, recipients, and sent-mail copies are stored in browser-unlocked encrypted payloads. The server stores placeholders for protected fields.",
            "Private mailbox storage reduces server-side search. Protected subject, body, sender, and recipient fields are not searchable by the server unless a future encrypted-search feature is explicitly enabled.",
            "Private mailbox storage does not encrypt every operational field. The server may still store message IDs, mailbox IDs, timestamps, delivery state, folder/label state, read/unread flags, spam/deleted/archive flags, attachment counts, and similar mailbox-management metadata."
          ]
        },
        %{
          subtitle: "Mail Delivery",
          paras: [],
          items: [
            "When you send or receive ordinary email, SMTP envelope data, routing headers, sender, recipient, subject, timestamps, message IDs, DKIM/SPF/DMARC headers, and server IPs/domains may be visible to Elektrine, receiving providers, sending providers, and intermediate mail systems.",
            "Outgoing messages must be processed in plaintext by Elektrine/Haraka long enough to format, sign, scan, route, and deliver them unless you use message-level encryption such as PGP.",
            "PGP or similar end-to-end content encryption can protect message contents from mail providers and relays, but it does not hide normal email routing metadata."
          ]
        }
      ]
    },
    %{
      title: "How We Use Information",
      blocks: [
        %{
          subtitle: nil,
          paras: ["We use information to:"],
          items: [
            "Provide, operate, and maintain Elektrine services.",
            "Send, receive, store, sync, filter, and display email and other user content.",
            "Authenticate users, protect accounts, prevent fraud and abuse, rate-limit automated activity, and investigate security issues.",
            "Debug failures, measure reliability, maintain backups, and improve product behavior.",
            "Respond to support, legal, or safety requests."
          ]
        }
      ]
    },
    %{
      title: "Security Measures",
      blocks: [
        %{
          subtitle: nil,
          paras: ["We use technical and organizational safeguards, including:"],
          items: [
            "TLS for supported web, API, and mail protocol connections.",
            "Hashed password storage and account security controls.",
            "Encryption at rest for supported stored content and optional private mailbox storage for browser-unlocked mail protection.",
            "Access controls, rate limits, spam/abuse protections, logging, and operational monitoring."
          ]
        },
        %{
          subtitle: nil,
          paras: [
            "No system can guarantee perfect security. You are responsible for protecting your account credentials and any private mailbox passphrase or device used to unlock encrypted mailbox content."
          ],
          items: []
        }
      ]
    },
    %{
      title: "Data Sharing",
      blocks: [
        %{
          subtitle: nil,
          paras: ["We do not sell your personal data. We may share or disclose information:"],
          items: [
            "With your direction or consent, such as when you send email to another provider or publish public content.",
            "With service providers that help us operate infrastructure, storage, delivery, security, monitoring, or support.",
            "To deliver email through the public email ecosystem, including DNS, SMTP, DKIM/SPF/DMARC, spam filtering, recipient providers, and remote mail servers.",
            "To comply with applicable law, legal process, or enforceable government requests.",
            "To protect Elektrine, our users, or the public from abuse, fraud, security threats, or harm."
          ]
        }
      ]
    },
    %{
      title: "Cookies and Local Storage",
      blocks: [
        %{
          subtitle: nil,
          paras: ["We use cookies and browser storage for:"],
          items: [
            "Session management and authentication.",
            "Security protections and CSRF prevention.",
            "User preferences such as theme, locale, and interface state.",
            "Private mailbox unlock state in the current browser tab when you choose to unlock protected mail."
          ]
        }
      ]
    },
    %{
      title: "Logs and Retention",
      blocks: [
        %{
          subtitle: nil,
          paras: [
            "We retain account data and user content while your account is active or as needed to provide the service. Operational logs may include IP addresses, request metadata, mail delivery events, rate-limit events, error messages, and security signals."
          ],
          items: [
            "Deleting messages or attachments removes them from the active mailbox storage path, subject to backups and operational retention.",
            "Account deletion removes or anonymizes personal data where feasible, subject to backups, legal obligations, fraud prevention, abuse records, and deliverability/security logs.",
            "Backups and logs may persist for a limited period after deletion before they expire through normal retention cycles."
          ]
        }
      ]
    },
    %{
      title: "Your Choices and Rights",
      blocks: [
        %{
          subtitle: nil,
          paras: ["Depending on your location and account status, you may be able to:"],
          items: [
            "Access, correct, export, or delete your account data.",
            "Delete messages, attachments, posts, contacts, aliases, and other stored content.",
            "Change privacy settings, notification settings, and mailbox encryption settings.",
            "Opt out of optional communications where available."
          ]
        }
      ]
    },
    %{
      title: "Children's Privacy",
      blocks: [
        %{
          subtitle: nil,
          paras: [
            "Our services are not directed to children under 13. We do not knowingly collect personal information from children under 13."
          ],
          items: []
        }
      ]
    },
    %{
      title: "International Data Transfers",
      blocks: [
        %{
          subtitle: nil,
          paras: [
            "Your data may be processed in countries other than your own. Where required, we use safeguards appropriate to the processing and providers involved."
          ],
          items: []
        }
      ]
    },
    %{
      title: "Changes to This Policy",
      blocks: [
        %{
          subtitle: nil,
          paras: [
            "We may update this policy periodically. We will notify you of significant changes by email, service notification, or posting an updated policy."
          ],
          items: []
        }
      ]
    }
  ]

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Privacy Policy", sections: @sections)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">Privacy Policy</h1>
          </header>

          <.card id="privacy-card" class="panel-card" body_class="p-0">
            <:body>
              <section
                :for={{section, index} <- Enum.with_index(@sections, 1)}
                class="border-b border-base-content/10 px-5 py-6 sm:px-7"
              >
                <h2 class="flex items-baseline gap-3 text-base font-semibold">
                  <span class="font-mono text-xs text-base-content/40">
                    {String.pad_leading(Integer.to_string(index), 2, "0")}
                  </span>
                  {section.title}
                </h2>

                <div :for={block <- section.blocks} class="mt-4">
                  <h3 :if={block.subtitle} class="text-sm font-semibold">
                    {block.subtitle}
                  </h3>

                  <p
                    :for={para <- block.paras}
                    class="mt-2 text-sm leading-relaxed text-base-content/70"
                  >
                    {para}
                  </p>

                  <ul
                    :if={block.items != []}
                    class="mt-2 list-disc space-y-1.5 pl-5 text-sm leading-relaxed text-base-content/70"
                  >
                    <li :for={item <- block.items}>{item}</li>
                  </ul>
                </div>
              </section>

              <section class="px-5 py-6 sm:px-7">
                <h2 class="flex items-baseline gap-3 text-base font-semibold">
                  <span class="font-mono text-xs text-base-content/40">
                    {String.pad_leading(Integer.to_string(length(@sections) + 1), 2, "0")}
                  </span>
                  Contact Us
                </h2>

                <p class="mt-3 text-sm leading-relaxed text-base-content/70">
                  For privacy-related questions or requests:
                  <a href={EmailAddresses.mailto("privacy")} class="link link-hover text-primary">
                    {EmailAddresses.local("privacy")}
                  </a>
                </p>
              </section>
            </:body>
          </.card>
        </div>
      </div>
    </div>
    """
  end
end
