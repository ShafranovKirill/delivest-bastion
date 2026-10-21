defmodule BastionWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import BastionWeb.ChannelCase

      @endpoint BastionWeb.Endpoint
    end
  end

  setup tags do
    Bastion.DataCase.setup_sandbox(tags)
    :ok
  end
end
