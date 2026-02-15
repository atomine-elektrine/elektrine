defmodule Elektrine.Captcha do
  @moduledoc """
  Simple server-side image captcha for Tor registration.
  Generates math problems rendered as images.
  """

  @word_numbers %{
    1 => "one",
    2 => "two",
    3 => "three",
    4 => "four",
    5 => "five",
    6 => "six",
    7 => "seven",
    8 => "eight",
    9 => "nine",
    10 => "ten",
    11 => "eleven",
    12 => "twelve"
  }

  @doc """
  Generates a new captcha.
  Returns {image_binary, answer_string, token}
  """
  def generate do
    {text, answer} = generate_problem()

    # Generate token and sign the answer
    token = generate_token(answer)

    # Generate image
    image_binary = render_captcha_image(text)

    {image_binary, answer, token}
  end

  defp generate_problem do
    case Enum.random(1..4) do
      1 -> generate_word_math()
      2 -> generate_mixed_math()
      3 -> generate_multiply()
      4 -> generate_two_step()
    end
  end

  # "seven + 4 = ?" - mix words and digits
  defp generate_word_math do
    a = Enum.random(1..12)
    b = Enum.random(1..12)
    op = Enum.random([:add, :subtract])

    a_str = if Enum.random([true, false]), do: @word_numbers[a], else: "#{a}"
    b_str = if Enum.random([true, false]), do: @word_numbers[b], else: "#{b}"

    case op do
      :add ->
        {"#{a_str} + #{b_str} = ?", Integer.to_string(a + b)}

      :subtract ->
        {max, min} = if a >= b, do: {a, b}, else: {b, a}
        max_str = if Enum.random([true, false]), do: @word_numbers[max], else: "#{max}"
        min_str = if Enum.random([true, false]), do: @word_numbers[min], else: "#{min}"
        {"#{max_str} - #{min_str} = ?", Integer.to_string(max - min)}
    end
  end

  # "3 x 4 = ?" - simple multiplication
  defp generate_multiply do
    a = Enum.random(2..9)
    b = Enum.random(2..9)
    op_symbol = Enum.random(["x", "*"])
    {"#{a} #{op_symbol} #{b} = ?", Integer.to_string(a * b)}
  end

  # "5 + 3 - 2 = ?" - two operations
  defp generate_two_step do
    a = Enum.random(5..15)
    b = Enum.random(1..5)
    c = Enum.random(1..5)

    case Enum.random(1..2) do
      1 ->
        # a + b - c
        {"#{a} + #{b} - #{c} = ?", Integer.to_string(a + b - c)}

      2 ->
        # a - b + c (ensure positive intermediate)
        if a > b do
          {"#{a} - #{b} + #{c} = ?", Integer.to_string(a - b + c)}
        else
          {"#{a} + #{b} - #{c} = ?", Integer.to_string(a + b - c)}
        end
    end
  end

  # Regular mixed format
  defp generate_mixed_math do
    a = Enum.random(10..25)
    b = Enum.random(3..12)

    if a > b do
      {"#{a} - #{b} = ?", Integer.to_string(a - b)}
    else
      {"#{a} + #{b} = ?", Integer.to_string(a + b)}
    end
  end

  @doc """
  Verifies a captcha answer against the token.
  """
  def verify(token, user_answer) when is_binary(token) and is_binary(user_answer) do
    user_answer = String.trim(user_answer)

    with {:ok, decoded} <- Base.decode64(token),
         [timestamp_str, answer_hash] <- String.split(decoded, ":", parts: 2),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         :ok <- verify_timestamp(timestamp),
         :ok <- verify_answer(user_answer, answer_hash) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_, _), do: {:error, :invalid_input}

  # Token expires after 5 minutes
  @token_ttl 300

  defp generate_token(answer) do
    timestamp = System.system_time(:second)
    answer_hash = hash_answer(answer)

    Base.encode64("#{timestamp}:#{answer_hash}")
  end

  defp hash_answer(answer) do
    secret = get_secret()

    :crypto.mac(:hmac, :sha256, secret, answer)
    |> Base.encode16(case: :lower)
  end

  defp get_secret do
    Application.get_env(:elektrine, ElektrineWeb.Endpoint)[:secret_key_base]
  end

  defp verify_timestamp(timestamp) do
    now = System.system_time(:second)
    age = now - timestamp

    if age >= 0 and age <= @token_ttl do
      :ok
    else
      {:error, :captcha_expired}
    end
  end

  defp verify_answer(user_answer, stored_hash) do
    expected_hash = hash_answer(user_answer)

    if Plug.Crypto.secure_compare(expected_hash, stored_hash) do
      :ok
    else
      {:error, :wrong_answer}
    end
  end

  defp render_captcha_image(text) do
    # Create a simple captcha image using Image library
    # White background, black text, some noise

    width = 200
    height = 60

    # Create base image with slight gradient/noise background
    {:ok, bg} = Image.new(width, height, color: [240, 240, 245])

    # Add some random noise lines
    bg = add_noise_lines(bg, width, height)

    # Render text
    text_image =
      Image.Text.text!(text,
        font_size: 28,
        text_fill_color: [30, 30, 40],
        padding: [15, 10]
      )

    # Compose text ON TOP of background
    {:ok, final} = Image.compose(bg, text_image, x: 20, y: 10)

    # Convert to PNG binary
    {:ok, binary} = Image.write(final, :memory, suffix: ".png")
    binary
  end

  defp add_noise_lines(image, width, height) do
    # Add random lines to make OCR harder
    Enum.reduce(1..5, image, fn _, img ->
      x1 = Enum.random(0..width)
      y1 = Enum.random(0..height)
      x2 = Enum.random(0..width)
      y2 = Enum.random(0..height)
      # Vary the gray intensity
      gray = Enum.random(120..180)

      case Image.Draw.line(img, x1, y1, x2, y2, color: [gray, gray, gray]) do
        {:ok, new_img} -> new_img
        _ -> img
      end
    end)
  end
end
