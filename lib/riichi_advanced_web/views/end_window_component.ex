defmodule RiichiAdvancedWeb.EndWindowComponent do
  use RiichiAdvancedWeb, :live_component

  def mount(socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class={["game-end-window", @visible_screen != :game_end && "inactive"]}>
      <div class="scoreboard">
        <%= for {{name, score}, place} <- @players
              |> Enum.map(fn {seat, player} -> {if player.nickname == nil do Atom.to_string(seat) else player.nickname end, player.score} end)
              |> Enum.sort_by(fn {_name, score} -> -score end)
              |> Enum.zip(["1st", "2nd", "3rd", "4th"]) do %>
          <div class="placement">
            <div class="placement-place"><%= place %></div>
            <div class="placement-name"><%= name %>: <span class="placement-score"><%= score %></span></div>
          </div>
        <% end %>
      </div>
      <.link href={~p"/"} class="goto-index-button">Return to menu</.link>
    </div>
    """
  end

  def handle_event("dismiss_error", _assigns, socket) do
    GenServer.cast(socket.assigns.game_state, :dismiss_error)
    {:noreply, socket}
  end
end
