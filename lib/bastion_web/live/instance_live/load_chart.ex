defmodule BastionWeb.InstanceLive.LoadChart do
  use BastionWeb, :html

  @width 600
  @height 120

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :series, :map, required: true
  attr :field, :atom, required: true
  attr :color, :string, required: true

  def load_chart(assigns) do
    %{from: from, to: to, points: points} = assigns.series
    values = points |> Enum.map(&Map.get(&1, assigns.field)) |> Enum.reject(&is_nil/1)

    assigns =
      assign(assigns,
        width: @width,
        height: @height,
        lines: lines(points, assigns.field, from, to),
        peak: values != [] && Enum.max(values),
        average: values != [] && Enum.sum(values) / length(values),
        from: from,
        to: to
      )

    ~H"""
    <div id={@id} class="min-w-0 space-y-1">
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 text-sm">
        <span class="font-semibold">{@title}</span>
        <span :if={@peak} class="text-xs text-base-content/60 tabular-nums">
          в среднем {percent(@average)} · максимум {percent(@peak)}
        </span>
      </div>
      <div class="relative rounded-box bg-base-200/60 p-2">
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          preserveAspectRatio="none"
          class="block h-28 w-full overflow-visible"
          role="img"
          aria-label={"#{@title}: максимум #{percent(@peak || 0)}"}
        >
          <line
            :for={level <- [50, 90]}
            x1="0"
            x2={@width}
            y1={y(level)}
            y2={y(level)}
            vector-effect="non-scaling-stroke"
            stroke-dasharray="4 4"
            class={(level == 90 && "stroke-warning/60") || "stroke-base-content/15"}
          />
          <g :for={line <- @lines} class={@color}>
            <polygon
              points={area(line)}
              class="fill-current opacity-15"
            />
            <polyline
              points={polyline(line)}
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
            />
          </g>
        </svg>
        <span class="pointer-events-none absolute right-3 top-1 text-[10px] text-warning/80">90%</span>
        <p
          :if={@lines == []}
          class="absolute inset-0 grid place-items-center text-sm text-base-content/50"
        >
          Данных пока нет
        </p>
      </div>
      <div class="flex justify-between text-[11px] text-base-content/50 tabular-nums">
        <span>{stamp(@from)}</span>
        <span>{stamp(@to)}</span>
      </div>
    </div>
    """
  end

  def percent(value), do: "#{round(value)}%"

  defp lines(points, field, from, to) do
    span = max(DateTime.diff(to, from), 1)
    gap = span / max(length(points), 1) * 3

    points
    |> Enum.reject(&is_nil(Map.get(&1, field)))
    |> Enum.map(&{DateTime.diff(&1.at, from), Map.get(&1, field)})
    |> Enum.chunk_while(
      [],
      fn
        {seconds, _value} = point, [{previous, _} | _] = acc when seconds - previous > gap ->
          {:cont, Enum.reverse(acc), [point]}

        point, acc ->
          {:cont, [point | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn line ->
      Enum.map(line, fn {seconds, value} -> {x(seconds, span), y(value)} end)
    end)
  end

  defp polyline([{x, y}]), do: polyline([{x - 1, y}, {x + 1, y}])
  defp polyline(line), do: Enum.map_join(line, " ", fn {x, y} -> "#{fmt(x)},#{fmt(y)}" end)

  defp area(line) do
    {first, _} = List.first(line)
    {last, _} = List.last(line)
    "#{fmt(first)},#{@height} " <> polyline(line) <> " #{fmt(last)},#{@height}"
  end

  defp x(seconds, span), do: seconds / span * @width
  defp y(value), do: @height - min(max(value, 0), 100) / 100 * @height

  defp fmt(number), do: :erlang.float_to_binary(number / 1, decimals: 1)

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%d.%m %H:%M UTC")
end
