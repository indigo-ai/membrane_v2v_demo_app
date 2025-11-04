import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :membrane_v2v_demo_app, MembraneV2vDemoAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "q+WLe6XaS2LXfH70BUu2t8laipRZnahM29i7zig6wGC2cXpJiI6txu842wTWUILp",
  server: false

# In test we don't send emails
config :membrane_v2v_demo_app, MembraneV2vDemoApp.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
