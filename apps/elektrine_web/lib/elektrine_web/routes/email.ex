defmodule ElektrineWeb.Routes.Email do
  @moduledoc false

  defmacro autoconfig_routes do
    quote do
      scope "/.well-known/autoconfig/mail", ElektrineWeb do
        pipe_through(:autoconfig)
        get("/config-v1.1.xml", AutoconfigController, :mozilla_autoconfig)
      end

      scope "/.well-known", ElektrineWeb do
        pipe_through(:well_known_text)
        get("/mta-sts.txt", MailSecurityController, :mta_sts)
      end

      scope "/mail", ElektrineWeb do
        pipe_through(:autoconfig)
        get("/config-v1.1.xml", AutoconfigController, :mozilla_autoconfig)
      end

      scope "/autodiscover", ElektrineWeb do
        pipe_through(:autoconfig)
        post("/autodiscover.xml", AutoconfigController, :microsoft_autodiscover)
        get("/autodiscover.xml", AutoconfigController, :mozilla_autoconfig)
      end

      scope "/", ElektrineWeb do
        pipe_through(:autoconfig)
        get("/mail.mobileconfig", AutoconfigController, :apple_mobileconfig)
      end
    end
  end

  defmacro wkd_routes do
    quote do
      scope "/.well-known/openpgpkey", alias: false do
        pipe_through(:api)
        get("/hu/:hash", ElektrineEmailWeb.WKDController, :get_key)
        get("/policy", ElektrineEmailWeb.WKDController, :policy)
      end
    end
  end

  defmacro dav_and_jmap_routes do
    quote do
      scope "/addressbooks", ElektrineEmailWeb.DAV do
        pipe_through(:dav)
        match(:propfind, "/:username", AddressBookController, :propfind_home)
        match(:propfind, "/:username/contacts", AddressBookController, :propfind_addressbook)
        match(:report, "/:username/contacts", AddressBookController, :report)
        get("/:username/contacts/:contact_uid", AddressBookController, :get_contact)
        put("/:username/contacts/:contact_uid", AddressBookController, :put_contact)
        delete("/:username/contacts/:contact_uid", AddressBookController, :delete_contact)
      end

      scope "/.well-known", ElektrineEmailWeb.JMAP do
        pipe_through(:jmap_discovery)
        get("/jmap", SessionController, :session)
      end

      scope "/jmap", ElektrineEmailWeb.JMAP do
        pipe_through(:jmap)
        post("/", APIController, :api)
        get("/eventsource", EventSourceController, :eventsource)
        get("/download/:account_id/:blob_id/:name", BlobController, :download)
        post("/upload/:account_id", BlobController, :upload)
      end
    end
  end

  defmacro public_browser_routes do
    quote do
      scope "/", alias: false do
        post("/unsubscribe/:token", ElektrineEmailWeb.UnsubscribeController, :one_click)
        post("/unsubscribe/confirm/:token", ElektrineEmailWeb.UnsubscribeController, :confirm)
        post("/resubscribe", ElektrineEmailWeb.UnsubscribeController, :resubscribe)
      end
    end
  end

  defmacro authenticated_browser_routes do
    quote do
      scope "/", alias: false do
        get(
          "/email/message/:message_id/attachment/:attachment_id/download",
          ElektrineEmailWeb.AttachmentController,
          :download
        )

        delete("/email/:id", ElektrineEmailWeb.EmailController, :delete)
        get("/email/:id/print", ElektrineEmailWeb.EmailController, :print)
        get("/email/:id/download_eml", ElektrineEmailWeb.EmailController, :download_eml)
        get("/email/:id/iframe_content", ElektrineEmailWeb.EmailController, :iframe_content)
        get("/email/export/download/:id", ElektrineEmailWeb.EmailController, :download_export)
      end
    end
  end

  defmacro admin_routes do
    quote do
      scope "/", alias: false do
        get("/aliases", ElektrineEmailWeb.Admin.AliasesController, :index)
        post("/aliases/:id/toggle", ElektrineEmailWeb.Admin.AliasesController, :toggle)
        delete("/aliases/:id", ElektrineEmailWeb.Admin.AliasesController, :delete)
        get("/forwarded-messages", ElektrineEmailWeb.Admin.AliasesController, :forwarded_messages)

        get("/mailboxes", ElektrineEmailWeb.Admin.MailboxesController, :index)
        delete("/mailboxes/:id", ElektrineEmailWeb.Admin.MailboxesController, :delete)
        get("/custom-domains", ElektrineEmailWeb.Admin.CustomDomainsController, :index)
        get("/haraka", ElektrineWeb.Admin.HarakaController, :index)

        get("/messages", ElektrineEmailWeb.Admin.MessagesController, :index)
        get("/messages/:id/view", ElektrineEmailWeb.Admin.MessagesController, :view)
        get("/messages/:id/raw", ElektrineEmailWeb.Admin.MessagesController, :view_raw)
        get("/users/:id/messages", ElektrineEmailWeb.Admin.MessagesController, :user_messages)

        get(
          "/users/:user_id/messages/:id",
          ElektrineEmailWeb.Admin.MessagesController,
          :view_user_message
        )

        get(
          "/users/:user_id/messages/:id/raw",
          ElektrineEmailWeb.Admin.MessagesController,
          :view_user_message_raw
        )

        get("/messages/:id/iframe", ElektrineEmailWeb.Admin.MessagesController, :iframe)
      end
    end
  end

  defmacro internal_api_routes do
    quote do
      post("/haraka/inbound", ElektrineEmailWeb.HarakaWebhookController, :create)

      post(
        "/haraka/verify-recipient",
        ElektrineEmailWeb.HarakaWebhookController,
        :verify_recipient
      )

      post("/haraka/auth", ElektrineEmailWeb.HarakaWebhookController, :auth)
      get("/haraka/domains", ElektrineEmailWeb.HarakaWebhookController, :domains)
    end
  end

  defmacro authenticated_api_routes do
    quote do
      get("/emails", ElektrineEmailWeb.API.EmailController, :index)
      get("/emails/search", ElektrineEmailWeb.API.EmailController, :search)
      get("/emails/counts", ElektrineEmailWeb.API.EmailController, :counts)
      post("/emails/bulk", ElektrineEmailWeb.API.EmailController, :bulk_action)
      get("/emails/:id", ElektrineEmailWeb.API.EmailController, :show)
      get("/emails/:id/attachments", ElektrineEmailWeb.API.EmailController, :list_attachments)

      get(
        "/emails/:id/attachments/:attachment_id",
        ElektrineEmailWeb.API.EmailController,
        :attachment
      )

      post("/emails/send", ElektrineEmailWeb.API.EmailController, :send_email)
      put("/emails/:id", ElektrineEmailWeb.API.EmailController, :update)
      put("/emails/:id/category", ElektrineEmailWeb.API.EmailController, :update_category)
      put("/emails/:id/reply-later", ElektrineEmailWeb.API.EmailController, :set_reply_later)
      delete("/emails/:id", ElektrineEmailWeb.API.EmailController, :delete)

      get("/aliases", ElektrineEmailWeb.API.AliasController, :index)
      post("/aliases", ElektrineEmailWeb.API.AliasController, :create)
      get("/aliases/:id", ElektrineEmailWeb.API.AliasController, :show)
      put("/aliases/:id", ElektrineEmailWeb.API.AliasController, :update)
      delete("/aliases/:id", ElektrineEmailWeb.API.AliasController, :delete)

      get("/mailbox", ElektrineEmailWeb.API.MailboxController, :show)
      get("/mailbox/stats", ElektrineEmailWeb.API.MailboxController, :stats)
    end
  end

  defmacro ext_api_read_routes do
    quote do
      get("/messages", ElektrineEmailWeb.API.ExtEmailController, :index)
      get("/messages/:id", ElektrineEmailWeb.API.ExtEmailController, :show)
    end
  end

  defmacro ext_api_write_routes do
    quote do
      post("/messages", ElektrineEmailWeb.API.ExtEmailController, :create)
    end
  end

  defmacro ext_contacts_routes do
    quote do
      get("/", ElektrineEmailWeb.API.ExtContactsController, :index)
      get("/:id", ElektrineEmailWeb.API.ExtContactsController, :show)
    end
  end

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/unsubscribe/:token", ElektrineEmailWeb.UnsubscribeLive.Show, :show)
        live("/email", ElektrineEmailWeb.EmailLive.Index, :index)
        live("/email/compose", ElektrineEmailWeb.EmailLive.Compose, :new)
        live("/email/view/:id", ElektrineEmailWeb.EmailLive.Show, :show)
        live("/email/:id/raw", ElektrineEmailWeb.EmailLive.Raw)
        live("/email/search", ElektrineEmailWeb.EmailLive.Search, :search)
        live("/email/settings", ElektrineEmailWeb.EmailLive.Settings, :index)
        live("/contacts", ElektrineEmailWeb.ContactsLive.Index, :index)
        live("/contacts/:id", ElektrineEmailWeb.ContactsLive.Index, :show)
        live("/calendar", ElektrineEmailWeb.EmailLive.Index, :calendar)
      end
    end
  end

  def path_prefixes do
    [
      "/email",
      "/emails",
      "/aliases",
      "/mailbox",
      "/jmap",
      "/calendar",
      "/.well-known/jmap",
      "/.well-known/mta-sts.txt",
      "/.well-known/autoconfig",
      "/autoconfig",
      "/unsubscribe",
      "/api/emails",
      "/api/aliases",
      "/api/mailbox",
      "/api/haraka",
      "/api/ext/v1/email",
      "/pripyat/mailboxes",
      "/pripyat/custom-domains",
      "/pripyat/haraka",
      "/pripyat/aliases",
      "/pripyat/forwarded-messages",
      "/pripyat/messages",
      "/pripyat/unsubscribe-stats"
    ]
  end

  def view_modules do
    [
      ElektrineEmailWeb.EmailLive.Compose,
      ElektrineEmailWeb.EmailLive.Index,
      ElektrineEmailWeb.EmailLive.Raw,
      ElektrineEmailWeb.EmailLive.Search,
      ElektrineEmailWeb.EmailLive.Settings,
      ElektrineEmailWeb.EmailLive.Show,
      ElektrineEmailWeb.ContactsLive.Index,
      ElektrineEmailWeb.UnsubscribeLive.Show
    ]
  end
end
