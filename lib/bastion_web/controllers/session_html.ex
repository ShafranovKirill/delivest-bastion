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
end
