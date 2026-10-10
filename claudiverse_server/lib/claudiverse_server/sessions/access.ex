defmodule ClaudiverseServer.Sessions.Access do
  @moduledoc """
  What a seat may use of claudiverse, set from the apps. Two independent
  settings:

  TOOLS (`access`, `POST /api/sessions/:id/access`):
    basic  role "worker": reporting and the shared tools (cv_request_human
           too, when paging is switched on)
    full   role "orchestrator": the whole tool set
    nil    derived, exactly as before levels existed: a runner's worker and a
           PLAIN session (origin "plain": a `claude` typed in a terminal) are
           basic, anything else full.
  ("notify" is still accepted as a level, from the first version of this API:
  basic tools with paging on.)

  PAGING (`notify_grant`, `POST /api/sessions/:id/notify`): may the seat page
  the operator (cv_request_human)?
    true / false  the operator's switch, optionally until `notify_until`, after
                  which it lapses to the derived value
    nil           derived, INDEPENDENT of the tool level: the seat's own flag
                  (its launcher's opt-in); a PLAIN session does not page until
                  the operator switches it on in the app (operator 2026-10-06:
                  "a fresh, clean claude in a terminal shouldn't have it by
                  default"). Setting Basic or Full changes the tools only; the
                  switch alone overrides paging.
  A runner's worker never pages (HumanRequests refuses it, whatever is set).
  """
  alias ClaudiverseServer.Sessions.Session

  @levels ~w(basic notify full)
  def levels, do: @levels

  @doc "`{role, can_notify}` for a seat, at `now`."
  def effective(%Session{} = s, now \\ DateTime.utc_now()), do: {role(s), can_notify?(s, now)}

  def role(%Session{access: a}) when a in ["basic", "notify"], do: "worker"
  def role(%Session{access: "full"}), do: "orchestrator"
  def role(%Session{origin: o}) when o in ["runner", "plain"], do: "worker"
  def role(%Session{}), do: "orchestrator"

  def can_notify?(%Session{} = s, now \\ DateTime.utc_now()) do
    case grant(s, now) do
      nil -> derived_notify(s)
      g -> g
    end
  end

  @doc "The operator's paging switch if it is in force at `now`, else nil."
  def grant(%Session{notify_grant: g, notify_until: until}, now \\ DateTime.utc_now()) do
    cond do
      is_nil(g) -> nil
      is_nil(until) -> g
      DateTime.compare(until, now) == :gt -> g
      true -> nil
    end
  end

  # Independent of the tool level: only the switch (grant/1) overrides this.
  defp derived_notify(%Session{access: "notify"}), do: true
  defp derived_notify(%Session{origin: "plain"}), do: false
  defp derived_notify(%Session{} = s), do: s.can_notify == true

  @doc "The seat's tool level: basic | full (a legacy \"notify\" level reads basic)."
  def level(%Session{} = s), do: if(role(s) == "worker", do: "basic", else: "full")
end
