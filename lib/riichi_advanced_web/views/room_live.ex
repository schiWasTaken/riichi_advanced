defmodule RiichiAdvancedWeb.RoomLive do
  use RiichiAdvancedWeb, :live_view

  def mount(params, _session, socket) do
    socket = socket
    |> assign(:session_id, params["id"])
    |> assign(:ruleset, params["ruleset"])
    |> assign(:display_name, params["ruleset"])
    |> assign(:nickname, Map.get(params, "nickname", ""))
    |> assign(:id, socket.id)
    |> assign(:players, %{east: nil, south: nil, west: nil, north: nil})
    |> assign(:room_state, nil)
    |> assign(:messages, [])
    |> assign(:symbols, %{east: "東", south: "南", west: "西", north: "北"})
    |> assign(:state, %Room{})
    if socket.root_pid != nil do
      # start a new room process, if it doesn't exist already
      room_spec = {RiichiAdvanced.RoomSupervisor, session_id: socket.assigns.session_id, ruleset: socket.assigns.ruleset, name: {:via, Registry, {:game_registry, Utils.to_registry_name("room", socket.assigns.ruleset, socket.assigns.session_id)}}}
      room_state = case DynamicSupervisor.start_child(RiichiAdvanced.RoomSessionSupervisor, room_spec) do
        {:ok, _pid} ->
          IO.puts("Starting room session #{socket.assigns.session_id}")
          [{room_state, _}] = Registry.lookup(:game_registry, Utils.to_registry_name("room_state", socket.assigns.ruleset, socket.assigns.session_id))
          room_state
        {:error, {:shutdown, error}} ->
          IO.puts("Error when starting room session #{socket.assigns.session_id}")
          IO.inspect(error)
          nil
        {:error, {:already_started, _pid}} ->
          IO.puts("Already started room session #{socket.assigns.session_id}")
          [{room_state, _}] = Registry.lookup(:game_registry, Utils.to_registry_name("room_state", socket.assigns.ruleset, socket.assigns.session_id))
          room_state
      end
      # subscribe to state updates
      Phoenix.PubSub.subscribe(RiichiAdvanced.PubSub, socket.assigns.ruleset <> "-room:" <> socket.assigns.session_id)
      # init a new player and get the current state
      [state] = GenServer.call(room_state, {:new_player, socket})
      socket = socket
      |> assign(:room_state, room_state)
      |> assign(:state, state)
      |> assign(:display_name, state.display_name)

      # fetch messages
      messages_init = RiichiAdvanced.MessagesState.init_socket(socket)
      socket = if Map.has_key?(messages_init, :messages_state) do
        socket = assign(socket, :messages_state, messages_init.messages_state)
        # subscribe to message updates
        Phoenix.PubSub.subscribe(RiichiAdvanced.PubSub, "messages:" <> socket.id)
        GenServer.cast(messages_init.messages_state, {:add_message, [
          %{text: "Entered room"},
          %{bold: true, text: socket.assigns.session_id},
          %{text: "for variant"},
          %{bold: true, text: socket.assigns.ruleset}
        ]})
        socket
      else socket end
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="container" class="room" phx-hook="ClickListener">
      <header>
        <h1>Room</h1>
        <div class="session">Room:&nbsp;
          <%= for tile <- String.split(@session_id, ",") do %>
            <div class={["tile", tile]}></div>
          <% end %>
        </div>
        <div class="private-toggle">
          <input id="private-toggle" type="checkbox" phx-click="private_toggled" phx-value-enabled={if @state.private do "true" else "false" end} checked={@state.private}>
          <label for="private-toggle">
            <%= if @state.private do %>
              Private
            <% else %>
              Public
            <% end %>
          </label>
        </div>
        <div class="variant">
          Variant:&nbsp;<b><%= @display_name %></b>
          <%= if @state.tutorial_link != nil do %>
            <br/>
            <a class="tutorial-link" href={@state.tutorial_link} target="_blank">
              <%= if @ruleset == "custom" do %>
                (Documentation)
              <% else %>
                (Rules)
              <% end %>
            </a>
          <% end %>
        </div>
      </header>
      <div class="seats">
        <%= for seat <- @state.available_seats do %>
          <%= if @state.seats[seat] != nil do %>
            <div class={["player-slot", @state.seats[seat] != nil && "filled"]}>
              <div class="player-slot-item">
                <div class="player-slot-label"><%= @symbols[seat] %></div>
                <div class="player-slot-button">
                  <div class="player-slot-button-text"><%= @state.seats[seat].nickname %></div>
                </div>
              </div>
              <%= if @state.seats[seat].id == @id do %>
                <button class="get-up-button" phx-cancellable-click="get_up">–</button>
              <% end %>
            </div>
          <% else %>
            <div class="player-slot empty">
              <div class="player-slot-item">
                  <div class="player-slot-label"><%= @symbols[seat] %></div>
                  <div class="player-slot-button" phx-cancellable-click="sit" phx-value-seat={seat}>
                    <div class="player-slot-button-text">Empty</div>
                  </div>
              </div>
              <%!-- dummy button for alignment --%>
              <button class="get-up-button">–</button>
            </div>
          <% end %>
        <% end %>
        <div class="seats-buttons circle-checkbox">
          <input id="shuffle-seats" type="checkbox" phx-click="shuffle_seats_toggled" phx-value-enabled={if @state.shuffle do "true" else "false" end} checked={@state.shuffle}>
          <label for="shuffle-seats">Shuffle seats on start?</label>
        </div>
      </div>
      <%!-- <div class="seats-buttons">
        <input id="shuffle-seats" type="checkbox" phx-click="shuffle_seats_toggled" phx-value-enabled={if @state.shuffle do "true" else "false" end} checked={@state.shuffle}>
        <label for="shuffle-seats">Shuffle seats on start?</label>
        <%= if Enum.any?(@state.seats, fn {_seat, player} -> player != nil && player.id == @id end) do %>
          <button class="get-up-button" phx-cancellable-click="get_up">Get up</button>
        <% end %>
        <%= if not Enum.all?(@state.seats, fn {_seat, player} -> player == nil end) do %>
          <%= if @state.starting do %>
            <button class="start-game-button">
              Starting game...
            </button>
          <% else %>
            <button class="start-game-button" phx-cancellable-click="start_game">
              Start game
              <%= if nil in Map.values(@state.seats) do %>
              (with AI)
              <% end %>
            </button>
          <% end %>
        <% end %>
      </div> --%>
      <.live_component module={RiichiAdvancedWeb.ErrorWindowComponent} id="error-window" game_state={@room_state} error={@state.error}/>
      <div class="top-right-container">
        <.live_component module={RiichiAdvancedWeb.MenuButtonsComponent} id="menu-buttons" />
      </div>
      <.live_component module={RiichiAdvancedWeb.MessagesComponent} id="messages" messages={@messages} />
      <div class="ruleset">
        <textarea readonly><%= @state.ruleset_json %></textarea>
      </div>
    </div>
    """
  end

  def handle_event("back", _assigns, socket) do
    socket = push_event(socket, "left-page", %{})
    socket = push_navigate(socket, to: ~p"/lobby/#{socket.assigns.ruleset}")
    {:noreply, socket}
  end

  def handle_event("double_clicked", _assigns, socket) do
    {:noreply, socket}
  end

  def handle_event("right_clicked", _assigns, socket) do
    {:noreply, socket}
  end

  def handle_event("sit", %{"seat" => seat}, socket) do
    GenServer.cast(socket.assigns.room_state, {:sit, socket.id, seat})
    {:noreply, socket}
  end

  def handle_event("get_up", _assigns, socket) do
    GenServer.cast(socket.assigns.room_state, {:get_up, socket.id})
    {:noreply, socket}
  end

  def handle_event("private_toggled", %{"enabled" => enabled}, socket) do
    enabled = enabled == "true"
    GenServer.cast(socket.assigns.room_state, {:toggle_private, not enabled})
    {:noreply, socket}
  end

  def handle_event("shuffle_seats_toggled", %{"enabled" => enabled}, socket) do
    enabled = enabled == "true"
    GenServer.cast(socket.assigns.room_state, {:toggle_shuffle_seats, not enabled})
    {:noreply, socket}
  end

  def handle_event("toggle_mod", %{"mod" => mod, "enabled" => enabled}, socket) do
    enabled = enabled == "true"
    GenServer.cast(socket.assigns.room_state, {:toggle_mod, mod, not enabled})
    {:noreply, socket}
  end

  def handle_event("toggle_category", %{"category" => category}, socket) do
    GenServer.cast(socket.assigns.room_state, {:toggle_category, category})
    {:noreply, socket}
  end

  def handle_event("reset_mods_to_default", _assigns, socket) do
    GenServer.cast(socket.assigns.room_state, :reset_mods_to_default)
    {:noreply, socket}
  end

  def handle_event("start_game", _assigns, socket) do
    GenServer.cast(socket.assigns.room_state, :start_game)
    {:noreply, socket}
  end

  def handle_info(%{topic: topic, event: "state_updated", payload: %{"state" => state}}, socket) do
    if topic == (socket.assigns.ruleset <> "-room:" <> socket.assigns.session_id) do
      socket = assign(socket, :state, state)
      socket = if state.started do
        seat = cond do
          get_in(state.seats.east.id)  == socket.id -> :east
          get_in(state.seats.south.id) == socket.id -> :south
          get_in(state.seats.west.id)  == socket.id -> :west
          get_in(state.seats.north.id) == socket.id -> :north
          true                                      -> :spectator
        end
        socket = push_event(socket, "left-page", %{})
        push_navigate(socket, to: ~p"/game/#{socket.assigns.ruleset}/#{socket.assigns.session_id}?nickname=#{socket.assigns.nickname}&seat=#{seat}")
      else socket end
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: topic, event: "textarea_updated", payload: %{"from_version" => from_version, "version" => version, "uuids" => uuids, "deltas" => deltas}}, socket) do
    if topic == (socket.assigns.ruleset <> "-room:" <> socket.assigns.session_id) do
      socket = push_event(socket, "apply-delta", %{from_version: from_version, version: version, uuids: uuids, deltas: deltas})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: topic, event: "messages_updated", payload: %{"state" => state}}, socket) do
    if topic == "messages:" <> socket.id do
      socket = assign(socket, :messages, state.messages)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end
end
