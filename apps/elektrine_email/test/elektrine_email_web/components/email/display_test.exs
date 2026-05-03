defmodule ElektrineEmailWeb.Components.Email.DisplayTest do
  use ExUnit.Case, async: true

  alias ElektrineEmailWeb.Components.Email.Display

  describe "clean_plain_text_body/1" do
    test "removes CSS-prefixed email template text" do
      zwnj = <<0xE2, 0x80, 0x8C>>

      body = """
      @import url('https://prod.statics.indeed.com/font.css');
      /* iOS BLUE LINKS */
      a[x-apple-data-detectors] { color: inherit !important; font-size: inherit !important; }
      @media all and (max-width: 600px) { .hide { display: none !important; } }
      img.submit-img + div { display: none }
      We'll help you get started #{zwnj} #{zwnj} Application submitted Operational Training Supervisor
      """

      cleaned = Display.clean_plain_text_body(body)

      refute String.contains?(cleaned, "@import")
      refute String.contains?(cleaned, "display: none")
      assert String.starts_with?(cleaned, "We'll help you get started")
      assert String.contains?(cleaned, "Application submitted")
    end

    test "preserves regular plain text" do
      assert Display.clean_plain_text_body("Hello\n\nWorld") == "Hello\n\nWorld"
    end
  end
end
