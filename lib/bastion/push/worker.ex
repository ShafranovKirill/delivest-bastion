defmodule Bastion.Push.Worker do
  use Oban.Worker, queue: :push, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"text" => text, "url" => url}}) do
    Bastion.Push.deliver(text, url)
    :ok
  end
end
