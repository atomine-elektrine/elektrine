defmodule Elektrine.Platform.Modules do
  @moduledoc """
  Runtime registry for hoster-selectable product modules.

  This is the control plane for turning Elektrine into a composable platform:
  features stay compiled, but hosters can decide which product modules are
  exposed and which module-specific runtimes are started.
  """

  @type module_id :: :chat | :social | :email | :vault | :vpn

  @modules [
    %{
      id: :chat,
      label: "Chat",
      app: :elektrine_chat,
      description: "Direct messages, group conversations, and messaging federation."
    },
    %{
      id: :social,
      label: "Social",
      app: :elektrine_social,
      description: "Timeline, communities, gallery, lists, remote profiles, and ActivityPub."
    },
    %{
      id: :email,
      label: "Email",
      app: :elektrine_email,
      description: "Mailbox UI, aliases, message APIs, Haraka, and JMAP."
    },
    %{
      id: :vault,
      label: "Vault",
      app: :elektrine_password_manager,
      description: "Client-side encrypted password manager."
    },
    %{
      id: :vpn,
      label: "VPN",
      app: :elektrine_vpn,
      description: "WireGuard VPN management, configs, and host integrations."
    }
  ]

  @module_ids Enum.map(@modules, & &1.id)
  @module_specs Map.new(@modules, &{&1.id, &1})
  @availability_markers %{
    social: Elektrine.Social,
    email: Elektrine.Email,
    vault: Elektrine.PasswordManager,
    vpn: Elektrine.VPN
  }

  @spec all() :: [module_id()]
  def all, do: @module_ids

  @spec compiled() :: [module_id()]
  def compiled do
    :elektrine
    |> Application.get_env(:compiled_platform_modules, @module_ids)
    |> normalize_enabled_modules()
    |> Enum.filter(&module_available?/1)
  end

  @spec compiled_specs() :: [map()]
  def compiled_specs do
    compiled()
    |> Enum.map(&spec/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec compiled?(module_id() | atom() | String.t() | nil) :: boolean()
  def compiled?(nil), do: true

  def compiled?(module_id) do
    normalized = normalize_module_id(module_id)
    normalized in compiled()
  end

  @spec default_enabled() :: [module_id()]
  def default_enabled, do: compiled()

  @spec specs() :: [map()]
  def specs, do: @modules

  @spec spec(module_id()) :: map() | nil
  def spec(module_id), do: Map.get(@module_specs, normalize_module_id(module_id))

  @spec known?(atom() | String.t()) :: boolean()
  def known?(module_id), do: not is_nil(spec(module_id))

  @spec enabled() :: [module_id()]
  def enabled do
    :elektrine
    |> Application.get_env(:platform_modules, [])
    |> Keyword.get(:enabled, default_enabled())
    |> normalize_enabled_modules()
    |> Enum.filter(&compiled?/1)
  end

  @spec enabled_specs() :: [map()]
  def enabled_specs do
    enabled()
    |> Enum.map(&spec/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec enabled?(module_id() | atom() | String.t() | nil) :: boolean()
  def enabled?(nil), do: true

  def enabled?(module_id) do
    normalized = normalize_module_id(module_id)
    normalized in enabled()
  end

  @spec normalize_enabled_modules(term()) :: [module_id()]
  def normalize_enabled_modules(value)

  def normalize_enabled_modules(nil), do: default_enabled()
  def normalize_enabled_modules(:all), do: default_enabled()
  def normalize_enabled_modules("all"), do: default_enabled()
  def normalize_enabled_modules("*"), do: default_enabled()
  def normalize_enabled_modules(:none), do: []
  def normalize_enabled_modules("none"), do: []
  def normalize_enabled_modules(""), do: []

  def normalize_enabled_modules(value) when is_atom(value) do
    normalize_enabled_modules([value])
  end

  def normalize_enabled_modules(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> normalize_enabled_modules()
  end

  def normalize_enabled_modules(value) when is_list(value) do
    value
    |> Enum.map(&normalize_module_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_enabled_modules(_value), do: default_enabled()

  defp module_available?(:chat), do: true

  defp module_available?(module_id) when is_atom(module_id) do
    case Map.fetch(@availability_markers, module_id) do
      {:ok, marker_module} -> Code.ensure_loaded?(marker_module)
      :error -> true
    end
  end

  defp module_available?(_module_id), do: false

  defp normalize_module_id(value) when value in @module_ids, do: value

  defp normalize_module_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "chat" -> :chat
      "social" -> :social
      "email" -> :email
      "vault" -> :vault
      "password_manager" -> :vault
      "password-manager" -> :vault
      "vpn" -> :vpn
      _ -> nil
    end
  end

  defp normalize_module_id(_value), do: nil
end
