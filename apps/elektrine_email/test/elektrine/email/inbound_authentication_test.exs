defmodule Elektrine.Email.InboundAuthenticationTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.InboundAuthentication

  test "normalizes inbound authentication results" do
    assert %{
             spf: :pass,
             dkim: :fail,
             dmarc: :none,
             arc: :none,
             aligned?: true
           } =
             InboundAuthentication.normalize(%{
               "spf" => "pass",
               "dkim" => "fail",
               "aligned" => "true"
             })
  end

  test "quarantines unauthenticated mail when policy requires it" do
    previous = Application.get_env(:elektrine, :inbound_email_auth_policy)
    Application.put_env(:elektrine, :inbound_email_auth_policy, :quarantine)

    on_exit(fn ->
      if previous do
        Application.put_env(:elektrine, :inbound_email_auth_policy, previous)
      else
        Application.delete_env(:elektrine, :inbound_email_auth_policy)
      end
    end)

    assert %{action: :quarantine} = InboundAuthentication.policy_decision(%{"spf" => "fail"})
  end

  test "does not authenticate SPF or DKIM when DMARC explicitly fails" do
    refute InboundAuthentication.authenticated?(%{
             "spf" => "pass",
             "dkim" => "pass",
             "dmarc" => "fail",
             "aligned" => true
           })
  end

  test "requires alignment when DMARC is absent" do
    refute InboundAuthentication.authenticated?(%{"spf" => "pass", "dmarc" => "none"})

    assert InboundAuthentication.authenticated?(%{
             "dkim" => "pass",
             "dmarc" => "none",
             "aligned" => true
           })
  end

  test "accepts DMARC and ARC passes" do
    assert InboundAuthentication.authenticated?(%{"dmarc" => "pass"})
    assert InboundAuthentication.authenticated?(%{"arc" => "pass", "dmarc" => "none"})
  end
end
