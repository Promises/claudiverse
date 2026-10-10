# A throwaway vault key so the credential paths (token refresh, enrolment) are
# TESTABLE. Without one every such test raises before reaching the code under
# test — which is why the refresh path shipped a cooldown-wiping bug with zero
# coverage (2026-09-20). Only set when the environment has none, so a real key
# is never shadowed; never a real key.
System.get_env("CV_VAULT_KEY") ||
  System.put_env("CV_VAULT_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ClaudiverseServer.Repo, :manual)
