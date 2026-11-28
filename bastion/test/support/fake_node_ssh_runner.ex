defmodule Bastion.FakeNodeSshRunner do
  def run(node, _token, _attrs) do
    send(Application.fetch_env!(:bastion, :ssh_test_pid), {:ssh_started, self(), node.id})

    receive do
      :continue -> {:error, :fake_disconnect}
    after
      5_000 -> {:error, :fake_timeout}
    end
  end
end
