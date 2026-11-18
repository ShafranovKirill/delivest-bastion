defmodule BastionWeb.SessionHTML do
  use BastionWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-sm py-16">
        <h1 class="text-2xl font-bold mb-6">Бастион</h1>
        <.form for={@form} id="login-form" action={~p"/login"} class="space-y-4">
          <.input field={@form[:login]} label="Логин" autocomplete="username" required />
          <.input
            field={@form[:password]}
            type="password"
            label="Пароль"
            autocomplete="current-password"
            required
          />
          <button type="submit" class="btn btn-primary w-full">Войти</button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  def code(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-sm py-16">
        <h1 class="text-2xl font-bold mb-2">Код из Telegram</h1>
        <p class="text-sm text-base-content/60 mb-6">
          Бот прислал 6 цифр. Код действует {Bastion.LoginCodes.ttl_minutes()} минут.
        </p>
        <.form for={@form} id="login-code-form" action={~p"/login/code"} class="space-y-4">
          <.input
            field={@form[:code]}
            label="Код"
            inputmode="numeric"
            autocomplete="one-time-code"
            pattern="[0-9]*"
            maxlength="6"
            autofocus
            required
            class="input w-full text-center text-2xl tracking-[0.5em] font-mono"
          />
          <button type="submit" class="btn btn-primary w-full">Войти</button>
        </.form>
        <.link href={~p"/login"} class="btn btn-ghost btn-sm w-full mt-2">
          Прислать новый код
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
