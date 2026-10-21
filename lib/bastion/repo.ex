defmodule Bastion.Repo do
  use Ecto.Repo,
    otp_app: :bastion,
    adapter: Ecto.Adapters.Postgres
end
