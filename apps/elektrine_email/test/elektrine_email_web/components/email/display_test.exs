defmodule ElektrineEmailWeb.Components.Email.DisplayTest do
  use ExUnit.Case, async: true

  alias ElektrineEmailWeb.Components.Email.Display

  describe "clean_plain_text_body/1" do
    test "preserves CSS-looking plain text and invisible Unicode byte-for-byte" do
      zwnj = <<0xE2, 0x80, 0x8C>>

      body = """
      @import url('https://prod.statics.indeed.com/font.css');
      /* iOS BLUE LINKS */
      a[x-apple-data-detectors] { color: inherit !important; font-size: inherit !important; }
      @media all and (max-width: 600px) { .hide { display: none !important; } }
      img.submit-img + div { display: none }
      We'll help you get started #{zwnj} #{zwnj} Application submitted Operational Training Supervisor
      """

      assert Display.clean_plain_text_body(body) == body
    end

    test "preserves indentation and CSS-like preambles" do
      body = """
      p { display:block;margin:13px 0; }
      @import url(https://fonts.googleapis.com/css2?family=Arvo);
      @import url(https://fonts.googleapis.com/css2?family=Lato);
      @media only screen and (max-width:600px){ .mj-column-per-100-0 { width:unset !important; max-width:unset; display:block !important; }}
      .emphasis { color:#a33600;font-weight:700; }
      .emphasis-2 { color:#537824;font-weight:700; }
      .emphasis-3 { color:#005cb9;font-weight:700; }Hi Maxfield We are excited you are interested in joining FHI.
      """

      assert Display.clean_plain_text_body(body) == body
    end

    test "preserves text that resembles a truncated font import" do
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

      assert Display.clean_plain_text_body(body) == body
    end

    test "preserves regular plain text" do
      assert Display.clean_plain_text_body("Hello\n\nWorld") == "Hello\n\nWorld"
    end

    test "preserves hexadecimal-looking URL query values byte-for-byte" do
      body = """
      Welcome aboard, Argonaut.

      Set your password and step into the Argonauts area:
      https://argonauts.odysseylinux.org/setup.php?token=84e4922a3e0a524d2c7a529a58b0d6bd712fe3f5c04e124d0f92b24f7bfb9e17

      This link is personal.
      """

      cleaned = Display.clean_plain_text_body(body)

      assert cleaned =~
               "https://argonauts.odysseylinux.org/setup.php?token=84e4922a3e0a524d2c7a529a58b0d6bd712fe3f5c04e124d0f92b24f7bfb9e17"
    end

    test "does not guess quoted-printable after MIME ingestion" do
      body = "Welcome=20aboard=2C=20Argonaut."
      assert Display.clean_plain_text_body(body) == body
    end

    test "preserves valid Romanian text and removes only NUL bytes" do
      body = "Mâine ne întâlnim în Târgu Mureș.\0"
      assert Display.clean_plain_text_body(body) == "Mâine ne întâlnim în Târgu Mureș."
    end
  end
end
