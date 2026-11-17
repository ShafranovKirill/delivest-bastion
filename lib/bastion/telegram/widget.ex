defmodule Bastion.Telegram.Widget do
  @moduledoc "Private Telegram status widgets with short-lived, single-use action tokens."

  alias Bastion.{Backups, Health, Images, Instances, Telegram}
  alias Bastion.Telegram.{Cards, Screens}

  @actions ~w(update start stop restart backup)

  def send(instance, chat_id, params \\ %{}) do
    if Telegram.private_chat?() and Telegram.allowed_chat?(chat_id) do
      {data, session} = state(instance)

      case Telegram.call(
             "sendWidget",
             Map.merge(params, %{
               chat_id: chat_id,
               html: html(),
               chat_data: data,
               allow_queries: true,
               caption:
                 "#{String.slice(instance.name, 0, 100)} · #{Screens.label(Health.evaluate(instance).level)}",
               reply_markup:
                 Telegram.keyboard(
                   Screens.links(instance)
                   |> then(&[&1, [{"Обычные кнопки", "f:" <> instance.id}]])
                   |> Enum.reject(&(&1 == []))
                 )
             })
           ) do
        {:ok, %{"message_id" => message_id}} = result ->
          Cards.session(chat_id, message_id, session)
          result

        error ->
          error
      end
    else
      {:error, :unsupported_chat}
    end
  end

  def edit(chat_id, message_id, instance, notice \\ nil, confirmation \\ nil) do
    {data, session} = state(instance, notice, confirmation)
    Cards.session(chat_id, message_id, session)

    Telegram.call("editMessageWidgetData", %{
      chat_id: chat_id,
      message_id: message_id,
      chat_data: data
    })
  end

  def resolve(%{
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => actor},
        "message_id" => message_id,
        "type" => %{"type" => "data"},
        "data" => data
      })
      when is_binary(data) do
    with true <-
           Telegram.private_chat?() and Telegram.allowed_chat?(chat_id) and
             Telegram.allowed_chat?(actor),
         [token, action] <- String.split(data, ":", parts: 2),
         {:ok, session} <- Cards.consume(chat_id, message_id, token, action),
         %{} = instance <- Instances.get_instance(session.instance_id),
         true <- permitted?(instance, action, session.confirmation) do
      {:ok, instance, action, session.confirmation}
    else
      _ -> :error
    end
  end

  def resolve(_), do: :error

  defp state(instance, notice \\ nil, confirmation \\ nil) do
    running = Instances.running_command(instance.id)
    health = Health.evaluate(instance)
    token = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
    actions = if instance.online and is_nil(running), do: available(instance), else: []
    actions = if confirmation, do: ["confirm", "cancel"], else: actions ++ ["refresh"]
    {current, available} = Images.site_versions(instance)

    buttons =
      Enum.map(actions, fn action ->
        label =
          case action do
            "confirm" -> "Да, выполнить"
            "cancel" -> "Отмена"
            "refresh" -> "Статус"
            _ -> Screens.action_label(action)
          end

        [label, token <> ":" <> action]
      end)

    data =
      encode_state(%{
        n: String.slice(instance.name, 0, 60),
        s: "#{Screens.emoji(health.level)} #{Screens.label(health.level)}",
        v:
          String.slice("#{current || "—"}#{if available, do: " → #{available}", else: ""}", 0, 80),
        m:
          String.slice(
            cond do
              confirmation -> "#{Instances.action_label(confirmation)} — подтвердить?"
              running -> "⏳ #{Instances.action_label(running.action)}…"
              notice -> notice
              true -> List.first(health.problems) || ""
            end,
            0,
            100
          ),
        b: buttons
      })

    {data,
     %{
       token: token,
       actions: actions,
       confirmation: confirmation,
       instance_id: instance.id,
       expires: System.monotonic_time(:second) + 900
     }}
  end

  # State is limited in UTF-8 bytes, including JSON escaping, by the Bot API.
  defp encode_state(state) do
    json = Jason.encode!(state)

    if byte_size(json) <= 1024 do
      json
    else
      key = Enum.max_by([:n, :v, :m], &byte_size(state[&1]))
      value = state[key]
      encode_state(Map.put(state, key, String.slice(value, 0, div(String.length(value), 2))))
    end
  end

  defp permitted?(_instance, action, _confirmation) when action in ["refresh", "cancel"], do: true
  defp permitted?(instance, "confirm", confirmation), do: permitted?(instance, confirmation, nil)

  defp permitted?(instance, action, _confirmation),
    do:
      instance.online and is_nil(Instances.running_command(instance.id)) and
        action in available(instance)

  defp available(instance) do
    power = if instance.stopped_at, do: "start", else: "stop"

    Enum.filter(
      @actions,
      &(&1 in ["update", power, "restart", "backup"] and
          &1 in instance.actions and (&1 != "backup" or Backups.supported?(instance)))
    )
  end

  def html do
    """
    <style>body{margin:12px;font-family:sans-serif}h3{margin:0 0 6px}p{margin:6px 0}.meta{color:var(--tg-theme-hint-color)}#buttons{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px}button{flex:1 1 40%;padding:9px;border-radius:8px}#message{min-height:20px}</style>
    <h3 id="name"></h3><p id="status"></p><p class="meta" id="version"></p><p id="message"></p><div id="buttons"></div>
    <script>
    const W=TelegramWidget;
    function render(){let d;try{d=JSON.parse(W.chatData)}catch(e){return}if(!d)return;
    document.getElementById('name').textContent=d.n;document.getElementById('status').textContent=d.s;
    document.getElementById('version').textContent='Версия сайта: '+d.v;document.getElementById('message').textContent=d.m;
    const root=document.getElementById('buttons');root.textContent='';
    d.b.forEach(function(item){const b=document.createElement('button');b.textContent=item[0];b.onclick=function(){
    W.request(item[1]).then(function(a){if(a.result)document.getElementById('message').textContent=a.result},function(){document.getElementById('message').textContent='Не удалось выполнить. Откройте свежую карточку через /sites.'});
    };root.appendChild(b)});}
    W.onEvent('chatDataChanged',render);render();W.ready();
    </script>
    """
  end
end
