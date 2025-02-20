defmodule RoomPlayer do
  defstruct [
    nickname: nil,
    id: "",
    ready: false
  ]
  use Accessible
end

defmodule Room do
  @initial_textarea Delta.Op.insert("{}")
  def initial_textarea, do: @initial_textarea
  defstruct [
    # params
    ruleset: nil,
    ruleset_json: nil,
    session_id: nil,
    # pids
    supervisor: nil,
    exit_monitor: nil,

    # control variables
    error: nil,

    # state
    seats: Map.new([:east, :south, :west, :north], fn seat -> {seat, nil} end),
    players: %{},
    shuffle: false,
    private: true,
    starting: false,
    started: false,
    mods: %{},
    textarea: [@initial_textarea],
    textarea_deltas: [[@initial_textarea]],
    textarea_delta_uuids: [],
    textarea_version: 0,
  ]
  use Accessible
end


defmodule RiichiAdvanced.RoomState do
  use GenServer

  def start_link(init_data) do
    IO.puts("Room supervisor PID is #{inspect(self())}")
    GenServer.start_link(
      __MODULE__,
      %Room{
        session_id: Keyword.get(init_data, :session_id),
        ruleset: Keyword.get(init_data, :ruleset)
      },
      name: Keyword.get(init_data, :name))
  end

  def init(state) do
    IO.puts("Room state PID is #{inspect(self())}")

    # lookup pids of the other processes we'll be using
    [{supervisor, _}] = Registry.lookup(:game_registry, Utils.to_registry_name("room", state.ruleset, state.session_id))
    [{exit_monitor, _}] = Registry.lookup(:game_registry, Utils.to_registry_name("exit_monitor_room", state.ruleset, state.session_id))

    # read in the ruleset
    ruleset_json = if state.ruleset == "custom" do
      RiichiAdvanced.ETSCache.get(state.session_id, ["{}"], :cache_rulesets) |> Enum.at(0)
    else
      case File.read(Application.app_dir(:riichi_advanced, "/priv/static/rulesets/#{state.ruleset <> ".json"}")) do
        {:ok, ruleset_json} -> ruleset_json
        {:error, _err}      -> nil
      end
    end

    # parse the ruleset now, in order to get the list of eligible mods
    {state, rules} = try do
      case Jason.decode(Regex.replace(~r{ //.*|/\*[.\n]*?\*/}, ruleset_json, "")) do
        {:ok, rules} -> {state, rules}
        {:error, err} ->
          state = show_error(state, "WARNING: Failed to read rules file at character position #{err.position}!\nRemember that trailing commas are invalid!")
          {state, %{}}
      end
    rescue
      ArgumentError ->
        state = show_error(state, "WARNING: Ruleset \"#{state.ruleset}\" doesn't exist!")
        {state, %{}}
    end

    default_mods = case RiichiAdvanced.ETSCache.get({state.ruleset, state.session_id}, [], :cache_mods) do
      [mods] -> mods
      []     -> Map.get(rules, "default_mods", [])
    end
    mods = Map.get(rules, "available_mods", [])

    # put params and process ids into state
    state = Map.merge(state, %Room{
      ruleset: state.ruleset,
      ruleset_json: ruleset_json,
      session_id: state.session_id,
      error: state.error,
      supervisor: supervisor,
      exit_monitor: exit_monitor,
      mods: mods |> Enum.with_index() |> Map.new(fn {mod, i} -> {mod["id"], %{
        enabled: mod["id"] in default_mods,
        index: i,
        name: mod["name"],
        desc: mod["desc"],
        deps: Map.get(mod, "deps", []),
        conflicts: Map.get(mod, "conflicts", [])
      }} end),
      textarea: [Delta.Op.insert(ruleset_json)],
    })

    # check if a lobby exists. if so, notify the lobby that this room now exists
    case Registry.lookup(:game_registry, Utils.to_registry_name("lobby_state", state.ruleset, "")) do
      [{lobby_state, _}] -> GenServer.cast(lobby_state, {:update_room_state, state.session_id, state})
      _                  -> nil
    end

    {:ok, state}
  end

  def put_seat(state, seat, val), do: Map.update!(state, :seats, &Map.put(&1, seat, val))
  def update_seat(state, seat, fun), do: Map.update!(state, :seats, &Map.update!(&1, seat, fun))
  def update_seats(state, fun), do: Map.update!(state, :seats, &Map.new(&1, fn {seat, player} -> {seat, fun.(player)} end))
  def update_seats_by_seat(state, fun), do: Map.update!(state, :seats, &Map.new(&1, fn {seat, player} -> {seat, fun.(seat, player)} end))
  
  def show_error(state, message) do
    state = Map.update!(state, :error, fn err -> if err == nil do message else err <> "\n\n" <> message end end)
    state = broadcast_state_change(state)
    state
  end

  def get_enabled_mods(state) do
    Map.get(state, :mods, %{})
    |> Enum.filter(fn {_mod, opts} -> opts.enabled end)
    |> Enum.sort_by(fn {_mod, opts} -> opts.index end)
    |> Enum.map(fn {mod, _opts} -> mod end)
  end

  def broadcast_state_change(state) do
    # IO.puts("broadcast_state_change called")
    RiichiAdvancedWeb.Endpoint.broadcast(state.ruleset <> "-room:" <> state.session_id, "state_updated", %{"state" => state})
    state
  end

  def broadcast_textarea_change(state, {from_version, version, uuids, deltas}) do
    # IO.puts("broadcast_textarea_change called")
    if version > from_version do
      RiichiAdvancedWeb.Endpoint.broadcast(state.ruleset <> "-room:" <> state.session_id, "textarea_updated", %{"from_version" => from_version, "version" => version, "uuids" => uuids, "deltas" => deltas})
    end
    state
  end

  def handle_call({:new_player, socket}, _from, state) do
    GenServer.call(state.exit_monitor, {:new_player, socket.root_pid, socket.id})
    nickname = if socket.assigns.nickname != "" do socket.assigns.nickname else "player" <> String.slice(socket.id, 10, 4) end
    state = put_in(state.players[socket.id], %RoomPlayer{nickname: nickname, id: socket.id})
    IO.puts("Player #{socket.id} joined room #{state.session_id} for ruleset #{state.ruleset}")
    state = broadcast_state_change(state)
    {:reply, [state], state}
  end

  def handle_call({:delete_player, socket_id}, _from, state) do
    state = update_seats(state, fn player -> if player == nil || player.id == socket_id do nil else player end end)
    {_, state} = pop_in(state.players[socket_id])
    IO.puts("Player #{socket_id} exited #{state.session_id} for ruleset #{state.ruleset}")
    state = if Enum.empty?(state.players) do
      # all players have left, shutdown
      # check if a lobby exists. if so, notify the lobby that this room no longer exists
      case Registry.lookup(:game_registry, Utils.to_registry_name("lobby_state", state.ruleset, "")) do
        [{lobby_state, _}] -> GenServer.cast(lobby_state, {:delete_room, state.session_id})
        _                  -> nil
      end
      IO.puts("Stopping room #{state.session_id} for ruleset #{state.ruleset}")
      DynamicSupervisor.terminate_child(RiichiAdvanced.RoomSessionSupervisor, state.supervisor)
      state
    else
      state = broadcast_state_change(state)
      state
    end
    {:reply, :ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # collaborative textarea

  def handle_call(:get_textarea, _from, state) do
    {:reply, {state.textarea_version, state.textarea}, state}
  end

  def handle_call({:update_textarea, client_version, uuids, client_deltas}, _from, state) do
    version_diff = state.textarea_version - client_version
    missed_deltas = Enum.take(state.textarea_deltas, version_diff)
    others_deltas = missed_deltas
    |> Enum.zip(Enum.take(state.textarea_delta_uuids, version_diff))
    |> Enum.reject(fn {_delta, uuid_list} -> Enum.any?(uuid_list, fn uuid -> uuid in uuids end) end)
    |> Enum.map(fn {delta, _uuid_list} -> delta end)

    client_delta = Enum.at(client_deltas, -1, [])
    transformed_delta = others_deltas |> Enum.reverse() |> Enum.reduce(client_delta, &Delta.transform(&1, &2, true))
    returned_deltas = [transformed_delta | missed_deltas] |> Enum.reverse()
    # IO.puts("""
    #   #{client_version} => #{state.textarea_version+1}
    #   Given the client delta #{inspect(client_delta)}
    #   and the missed deltas #{inspect(missed_deltas)}
    #   where others contributed #{inspect(others_deltas)}
    #   we transform the client delta into #{inspect(transformed_delta)}
    #   and return #{inspect(returned_deltas)}
    # """)

    returned_uuids = [uuids | Enum.take(state.textarea_delta_uuids, version_diff)] |> Enum.reverse()
    state = if not Enum.empty?(client_delta) do
      state = Map.update!(state, :textarea_version, & &1 + 1)
      state = Map.update!(state, :textarea_deltas, &[transformed_delta | &1])
      state = Map.update!(state, :textarea_delta_uuids, &[uuids | &1])
      state = Map.update!(state, :textarea, &Delta.compose(&1, transformed_delta))
      state
    else state end
    change = {client_version, state.textarea_version, returned_uuids, returned_deltas}
    state = broadcast_textarea_change(state, change)
    if state.textarea_version > 100 do
      GenServer.cast(self(), :delta_compression)
    end
    {:reply, :ok, state}
  end



  def handle_cast(:delta_compression, state) do
    state = Map.put(state, :textarea_version, 0)
    compressed = state.textarea_deltas
    |> Enum.reverse()
    |> Delta.compose_all()
    state = Map.put(state, :textarea_deltas, [compressed])
    state = Map.update!(state, :textarea_delta_uuids, fn uuids -> [uuids |> Enum.take(99) |> Enum.concat()] end)
    state = Map.put(state, :textarea, compressed)
    change = {-1, 0, state.textarea_delta_uuids, state.textarea_deltas}
    state = broadcast_textarea_change(state, change)
    {:noreply, state}
  end

  def handle_cast({:sit, socket_id, seat}, state) do
    seat = case seat do
      "south" -> :south
      "west"  -> :west
      "north" -> :north
      _       -> :east
    end
    state = if state.seats[seat] == nil do
      state = update_seats(state, fn player -> if player == nil || player.id == socket_id do nil else player end end)
      # state = put_in(state.seats[seat], state.players[socket_id])
      state = put_seat(state, seat, state.players[socket_id])
      IO.puts("Player #{socket_id} sat in seat #{seat}")
      state
    else state end
    state = broadcast_state_change(state)
    {:noreply, state}
  end

  def handle_cast({:toggle_private, enabled}, state) do
    state = Map.put(state, :private, enabled)
    state = broadcast_state_change(state)
    {:noreply, state}
  end

  def handle_cast({:toggle_shuffle_seats, enabled}, state) do
    state = Map.put(state, :shuffle, enabled)
    state = broadcast_state_change(state)
    {:noreply, state}
  end

  def handle_cast({:toggle_mod, mod, enabled}, state) do
    state = put_in(state.mods[mod].enabled, enabled)
    state = if enabled do
      # enable dependencies and disable conflicting mods
      state = for dep <- state.mods[mod].deps, reduce: state do
        state -> put_in(state.mods[dep].enabled, true)
      end
      for conflict <- state.mods[mod].conflicts, reduce: state do
        state -> put_in(state.mods[conflict].enabled, false)
      end
    else
      # disable dependent mods
      for {dep, opts} <- state.mods, mod in opts.deps, reduce: state do
        state -> put_in(state.mods[dep].enabled, false)
      end
    end
    state = broadcast_state_change(state)
    {:noreply, state}
  end

  def handle_cast({:get_up, socket_id}, state) do
    state = update_seats(state, fn player -> if player == nil || player.id == socket_id do nil else player end end)
    state = broadcast_state_change(state)
    {:noreply, state}
  end

  def handle_cast(:start_game, state) do
    state = Map.put(state, :starting, true)
    state = broadcast_state_change(state)
    mods = if state.ruleset == "custom" do [] else get_enabled_mods(state) end
    if state.ruleset == "custom" do
      RiichiAdvanced.ETSCache.put(state.session_id, Enum.at(state.textarea, 0)["insert"], :cache_rulesets)
    end
    game_spec = {RiichiAdvanced.GameSupervisor, session_id: state.session_id, ruleset: state.ruleset, mods: mods, name: {:via, Registry, {:game_registry, Utils.to_registry_name("game", state.ruleset, state.session_id)}}}
    state = case DynamicSupervisor.start_child(RiichiAdvanced.GameSessionSupervisor, game_spec) do
      {:ok, _pid} ->
        IO.puts("Starting game session #{state.session_id}")
        # shuffle seats
        state = if state.shuffle do
          Map.update!(state, :seats, fn seats -> Map.keys(seats) |> Enum.zip(Map.values(seats) |> Enum.shuffle()) |> Map.new() end)
        else state end
        state = Map.put(state, :started, true)
        state
      {:error, {:shutdown, error}} ->
        IO.puts("Error when starting game session #{state.session_id}")
        IO.inspect(error)
        state = Map.put(state, :starting, false)
        state
      {:error, {:already_started, _pid}} ->
        IO.puts("Already started game session #{state.session_id}")
        state = show_error(state, "A game session for this variant with this same room ID is already in play -- please leave the room and try entering it directly!")
        state = Map.put(state, :starting, false)
        state
    end
    state = broadcast_state_change(state)
    {:noreply, state}
  end

  def handle_cast(:dismiss_error, state) do
    state = Map.put(state, :error, nil)
    state = broadcast_state_change(state)
    {:noreply, state}
  end

end
