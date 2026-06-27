import Config

if System.get_env("STRIPE_SECRET_KEY") do
  config :stripity_stripe,
    api_key: System.get_env("STRIPE_SECRET_KEY"),
    signing_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
end
