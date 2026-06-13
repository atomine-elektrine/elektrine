defmodule Elektrine.Mailer.DeliveryWorker do
  @moduledoc """
  Delivers transactional Swoosh emails through Oban so transient mail-server
  failures are retried instead of dropped.
  """

  use Oban.Worker, queue: :email, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email_args}}) do
    case email_args |> to_email() |> Elektrine.Mailer.deliver() do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(%Swoosh.Email{} = email) do
    %{"email" => to_args(email)}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  defp to_args(%Swoosh.Email{} = email) do
    %{
      "from" => address_to_args(email.from),
      "to" => Enum.map(email.to || [], &address_to_args/1),
      "cc" => Enum.map(email.cc || [], &address_to_args/1),
      "bcc" => Enum.map(email.bcc || [], &address_to_args/1),
      "reply_to" => address_to_args(email.reply_to),
      "subject" => email.subject,
      "text_body" => email.text_body,
      "html_body" => email.html_body,
      "headers" => email.headers || %{}
    }
  end

  defp to_email(args) do
    %Swoosh.Email{
      from: args_to_address(args["from"]),
      to: Enum.map(args["to"] || [], &args_to_address/1),
      cc: Enum.map(args["cc"] || [], &args_to_address/1),
      bcc: Enum.map(args["bcc"] || [], &args_to_address/1),
      reply_to: args_to_address(args["reply_to"]),
      subject: args["subject"],
      text_body: args["text_body"],
      html_body: args["html_body"],
      headers: args["headers"] || %{}
    }
  end

  defp address_to_args(nil), do: nil
  defp address_to_args({name, address}), do: [name, address]

  defp args_to_address(nil), do: nil
  defp args_to_address([name, address]), do: {name, address}
end
