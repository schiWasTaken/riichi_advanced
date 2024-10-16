
defmodule RiichiAdvanced.GameState.Marking do
  import RiichiAdvanced.GameState

  def initialize_marking(state) do
    state = Map.put(state, :marking, %{
      # for example: 
      # east: {
      #   done: false,
      #   hand: {
      #     marked: [{:"2m", :east, 4}],
      #     needed: 1,
      #     restrictions: ["same_suit_as_marked_discard"]
      #   },
      #   discard: {
      #     marked: [],
      #     needed: 1,
      #     restrictions: ["same_suit_as_marked_hand"]
      #   },
      # }
      east: %{},
      south: %{},
      west: %{},
      north: %{}
    })
    state
  end

  def setup_marking(state, seat, to_mark) do
    state = put_in(state.marking[seat], for {target, amount, restrictions} <- to_mark, reduce: %{done: false} do
      marked -> case target do
        "hand"    -> Map.put(marked, :hand, %{marked: [], needed: amount, restrictions: restrictions})
        "discard" -> Map.put(marked, :discard, %{marked: [], needed: amount, restrictions: restrictions})
        _         ->
          GenServer.cast(self(), {:show_error, "Unknown mark target: #{inspect(target)}"})
          marked
      end
    end)
    state
  end

  def needs_marking?(state, seat) do
    Enum.any?(state.marking[seat], fn {source, mark_info} -> not (source == :done) && length(mark_info.marked) < mark_info.needed end)
  end

  defp get_tile(state, seat, index, source) do
    case source do
      :hand    -> state.players[seat].hand ++ state.players[seat].draw |> Enum.at(index)
      :discard -> state.players[seat].pond |> Enum.at(index)
      _        ->
        GenServer.cast(self(), {:show_error, "Unknown mark source: #{inspect(source)}"})
        nil
    end
  end

  def can_mark?(state, marking_player, seat, index, source) do
    tile = get_tile(state, seat, index, source)
    mark_info = state.marking[marking_player][source]
    marked_enough = mark_info != nil && length(mark_info.marked) >= mark_info.needed
    already_marked = is_marked?(state, marking_player, seat, index, source)
    mark_info != nil && not marked_enough && not already_marked && Enum.all?(mark_info.restrictions, fn restriction ->
      case restriction do
        "match_suit"        ->
          case source do
            :hand    ->
              case state.marking[marking_player].discard.marked do
                []                  -> Riichi.is_suited?(tile)
                [{tile2, _, _} | _] ->
                  IO.puts("Checking if same suit: #{inspect(tile)}, #{inspect(tile2)}")
                  Riichi.same_suit?(tile, tile2)
              end
            :discard -> 
              case state.marking[marking_player].hand.marked do
                []                  -> Riichi.is_suited?(tile)
                [{tile2, _, _} | _] ->
                  IO.puts("Checking if same suit: #{inspect(tile)}, #{inspect(tile2)}")
                  Riichi.same_suit?(tile, tile2)
              end
            _        ->
              GenServer.cast(self(), {:show_error, "Unknown mark source: #{inspect(source)}"})
              true
          end
        "match_called_tile" -> Utils.same_tile(tile, get_last_call_action(state).called_tile, state.players[marking_player].tile_aliases)
        "7z"                -> tile == :"7z"
        "self"              -> seat == state.marking.marking_player
        _                   ->
          GenServer.cast(self(), {:show_error, "Unknown restriction: #{inspect(restriction)}"})
          true
      end
    end)
  end

  def is_marked?(state, marking_player, seat, index, source) do
    case source do
      :hand    -> Map.has_key?(state.marking[marking_player], :hand) && Enum.any?(state.marking[marking_player].hand.marked, fn {_tile, seat2, index2} -> seat == seat2 && index == index2 end)
      :discard -> Map.has_key?(state.marking[marking_player], :discard) && Enum.any?(state.marking[marking_player].discard.marked, fn {_tile, seat2, index2} -> seat == seat2 && index == index2 end)
      _        ->
        GenServer.cast(self(), {:show_error, "Unknown mark source: #{inspect(source)}"})
        false
    end
  end

  def mark_tile(state, marking_player, seat, index, source) do
    case source do
      :hand    -> update_in(state.marking[marking_player].hand.marked, fn marked -> marked ++ [{get_tile(state, seat, index, source), seat, index}] end)
      :discard -> update_in(state.marking[marking_player].discard.marked, fn marked -> marked ++ [{get_tile(state, seat, index, source), seat, index}] end)
      _        ->
        GenServer.cast(self(), {:show_error, "Unknown mark source: #{inspect(source)}"})
        state
    end
  end

  def clear_marked_objects(state, seat) do
    update_in(state.marking[seat], &Map.new(&1, fn {source, mark_info} -> {source, if source == :done do false else Map.put(mark_info, :marked, []) end} end))
  end

  def reset_marking(state, marking_player) do
    state = put_in(state.marking[marking_player], %{})
    state
  end
end
