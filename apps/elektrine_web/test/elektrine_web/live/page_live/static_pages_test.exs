defmodule ElektrineWeb.PageLive.StaticPagesTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "about page renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/about")
    assert html =~ "About Elektrine"
    assert html =~ "Federation"
  end

  test "contact page renders every channel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/contact")
    assert html =~ "Contact"

    for label <- ["General", "Support", "Security", "Privacy"] do
      assert html =~ label
    end
  end

  test "faq page renders grouped questions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/faq")
    assert html =~ "Frequently Asked Questions"
    assert html =~ "What is Elektrine?"
    assert html =~ "Which federated protocols are supported?"
  end

  test "terms page renders numbered sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/terms")
    assert html =~ "Terms of Service"
    assert html =~ "Acceptance of Terms"
    assert html =~ "Limitation of Liability"
  end

  test "home page footer links the info and policy pages", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    for {path, label} <- [
          {"/about", "About"},
          {"/contact", "Contact"},
          {"/faq", "FAQ"},
          {"/terms", "Terms of Service"},
          {"/privacy", "Privacy Policy"},
          {"/canary", "Canary"}
        ] do
      assert html =~ ~s(href="#{path}"), "expected footer link to #{path}"
      assert html =~ label
    end
  end

  test "privacy page renders sections and subsections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/privacy")
    assert html =~ "Privacy Policy"
    assert html =~ "Information We Collect"
    assert html =~ "Mail Delivery"
  end
end
