defmodule Xamal.Configuration.DeployQueue do
  @moduledoc """
  The deploy queue, which runs one deploy of a service at a time.

    * `wait_timeout`, seconds a deploy waits for the one ahead of it before
      giving up (default 1800).
    * `hold_timeout`, seconds after which the host frees a held lock on its
      own, so a deploy whose machine vanished never blocks the next one
      forever (default 3600). Keep it well above the longest deploy.
    * `follow`, a git ref such as `"origin/main"`. A deploy that had to wait
      fetches it and, when it already contains the commit being deployed,
      deploys it instead, so one deploy ships every change that queued up
      behind the last one. Only a `builder.remote` build can follow, since the
      other builders build the working tree. Off when unset.
  """

  defstruct wait_timeout: 1800, hold_timeout: 3600, follow: nil

  @type t :: %__MODULE__{
          wait_timeout: pos_integer(),
          hold_timeout: pos_integer(),
          follow: String.t() | nil
        }

  def new(config) when is_map(config) do
    %__MODULE__{
      wait_timeout: Map.get(config, "wait_timeout", 1800),
      hold_timeout: Map.get(config, "hold_timeout", 3600),
      follow: Map.get(config, "follow")
    }
  end

  def new(_), do: %__MODULE__{}
end
