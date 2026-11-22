defmodule Bastion.Releases.Bundle do
  use Ecto.Schema

  @primary_key {:version, :string, autogenerate: false}

  schema "release_bundles" do
    field :manifest, :map
    timestamps(type: :utc_datetime_usec)
  end
end
