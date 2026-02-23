# Umbrella root seed entrypoint.
#
# Run from umbrella root:
#   mix run priv/repo/seeds.exs
#
# This forwards to the main app seed script.

Code.eval_file(Path.expand("../../apps/elektrine/priv/repo/seeds.exs", __DIR__))
