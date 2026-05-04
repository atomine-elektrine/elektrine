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

    test "removes single-letter selector and font import preambles" do
      body = """
      p { display:block;margin:13px 0; }
      @import url(https://fonts.googleapis.com/css2?family=Arvo);
      @import url(https://fonts.googleapis.com/css2?family=Lato);
      @media only screen and (max-width:600px){ .mj-column-per-100-0 { width:unset !important; max-width:unset; display:block !important; }}
      .emphasis { color:#a33600;font-weight:700; }
      .emphasis-2 { color:#537824;font-weight:700; }
      .emphasis-3 { color:#005cb9;font-weight:700; }Hi Maxfield We are excited you are interested in joining FHI.
      """

      cleaned = Display.clean_plain_text_body(body)

      refute String.contains?(cleaned, "display:block")
      refute String.contains?(cleaned, "@import")
      refute String.contains?(cleaned, ".emphasis")
      assert cleaned == "Hi Maxfield We are excited you are interested in joining FHI."
    end

    test "removes truncated font import fragments before CSS preambles" do
      zwnj = <<0xE2, 0x80, 0x8C>>

      body = """
      700&display=swap');

      /* iOS BLUE LINKS */
      a[x-apple-data-detectors] {
        color: inherit !important;
        font-size: inherit !important;
      }

      @media all and (max-width: 600px) {
        .hide { display: none !important; }
      }

      [style*='Noto Sans'] {
        font-family: 'Indeed Sans', 'Noto Sans', Helvetica, Arial, sans-serif !important;
      }

      Find immediate job opportunities #{zwnj} #{zwnj}

      Find JobsSign in

      Apply now to companies hiring fast
      """

      cleaned = Display.clean_plain_text_body(body)

      refute String.contains?(cleaned, "display=swap")
      refute String.contains?(cleaned, "iOS BLUE LINKS")
      refute String.contains?(cleaned, "x-apple-data-detectors")
      refute String.contains?(cleaned, "Noto Sans")
      assert String.starts_with?(cleaned, "Find immediate job opportunities")
      assert String.contains?(cleaned, "Apply now to companies hiring fast")
    end

    test "preserves regular plain text" do
      assert Display.clean_plain_text_body("Hello\n\nWorld") == "Hello\n\nWorld"
    end
  end
end
