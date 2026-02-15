# Script for creating initial invite codes
# Run `mix run priv/repo/seeds_invite_codes.exs`

alias Elektrine.Accounts

# Create a few sample invite codes
codes = [
  %{
    code: "WELCOME2025",
    max_uses: 10,
    note: "Initial welcome code for new users",
    is_active: true
  },
  %{
    code: "BETA2025",
    max_uses: 5,
    expires_at: DateTime.utc_now() |> DateTime.add(30, :day),
    note: "Beta testing invite code - expires in 30 days",
    is_active: true
  },
  %{
    code: "TESTCODE",
    max_uses: 1,
    note: "Single use test code",
    is_active: true
  }
]

Enum.each(codes, fn code_attrs ->
  case Accounts.create_invite_code(code_attrs) do
    {:ok, invite_code} ->
      IO.puts("Created invite code: #{invite_code.code}")

    {:error, changeset} ->
      IO.puts("Failed to create invite code: #{inspect(changeset.errors)}")
  end
end)

IO.puts("\nInvite code statistics:")
stats = Accounts.get_invite_code_stats()
IO.puts(inspect(stats, pretty: true))
