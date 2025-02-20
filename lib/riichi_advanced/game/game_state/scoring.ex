
defmodule RiichiAdvanced.GameState.Scoring do
  import RiichiAdvanced.GameState

  def get_yaku(state, yaku_list, seat, winning_tile, win_source, minipoints \\ 0, existing_yaku \\ []) do
    context = %{
      seat: seat,
      winning_tile: winning_tile,
      win_source: win_source,
      minipoints: minipoints,
      existing_yaku: existing_yaku
    }
    eligible_yaku = yaku_list
      |> Enum.filter(fn %{"display_name" => _name, "value" => _value, "when" => cond_spec} -> check_cnf_condition(state, cond_spec, context) end)
      |> Enum.map(fn %{"display_name" => name, "value" => value, "when" => _cond_spec} -> {name, value} end)
    eligible_yaku = existing_yaku ++ eligible_yaku
    yaku_map = Enum.reduce(eligible_yaku, %{}, fn {name, value}, acc -> Map.update(acc, name, value, & &1 + value) end)
    eligible_yaku = eligible_yaku
      |> Enum.map(fn {name, _value} -> name end)
      |> Enum.uniq()
      |> Enum.map(fn name -> {name, yaku_map[name]} end)
    if Map.has_key?(state.rules, "yaku_precedence") do
      excluded_yaku = Enum.flat_map(eligible_yaku, fn {name, _value} -> Map.get(state.rules["yaku_precedence"], name, []) end)
      Enum.reject(eligible_yaku, fn {name, _value} -> name in excluded_yaku end)
    else eligible_yaku end
  end

  def apply_joker_assignment(state, seat, joker_assignment, winning_tile) do
    orig_hand = state.players[seat].hand
    non_flower_calls = Enum.reject(state.players[seat].calls, fn {call_name, _call} -> call_name in ["flower", "start_flower", "start_joker"] end)
    assigned_hand = orig_hand |> Enum.with_index() |> Enum.map(fn {tile, ix} -> if joker_assignment[ix] != nil do joker_assignment[ix] else tile end end)
    assigned_calls = non_flower_calls
    |> Enum.with_index()
    |> Enum.map(fn {{call_name, call}, i} -> {call_name, call |> Enum.with_index() |> Enum.map(fn {{tile, sideways}, ix} -> {Map.get(joker_assignment, length(orig_hand) + 1 + 3*i + ix, tile), sideways} end)} end)
    assigned_winning_tile = Map.get(joker_assignment, length(orig_hand), winning_tile)
    assigned_winning_hand = assigned_hand ++ Enum.flat_map(assigned_calls, &Riichi.call_to_tiles/1) ++ [assigned_winning_tile]
    state = update_player(state, seat, fn player -> %Player{ player | hand: assigned_hand, calls: assigned_calls, winning_hand: assigned_winning_hand } end)
    {state, assigned_winning_tile}
  end

  def _seat_scores_points(state, yaku_list, min_points, seat, winning_tile, win_source) do
    # t = System.system_time(:millisecond)
    joker_assignments = if Enum.empty?(state.players[seat].tile_mappings) do [%{}] else
      RiichiAdvanced.SMT.match_hand_smt_v2(state.smt_solver, state.players[seat].hand ++ [winning_tile], state.players[seat].calls, state.all_tiles, translate_match_definitions(state, ["win"]), state.players[seat].tile_ordering, state.players[seat].tile_mappings)
    end
    # IO.puts("seat_scores_points SMT time: #{inspect(System.system_time(:millisecond) - t)} ms")
    # IO.inspect(Process.info(self(), :current_stacktrace))

    IO.puts("Joker assignments: #{inspect(joker_assignments)}")
    joker_assignments = if Enum.empty?(joker_assignments) do [%{}] else joker_assignments end
    Enum.any?(joker_assignments, fn joker_assignment ->
      {state, assigned_winning_tile} = apply_joker_assignment(state, seat, joker_assignment, winning_tile)
      minipoints = Riichi.calculate_fu(state.players[seat].hand, state.players[seat].calls, assigned_winning_tile, win_source, Riichi.get_seat_wind(state.kyoku, seat), Riichi.get_round_wind(state.kyoku), state.players[seat].tile_ordering, state.players[seat].tile_ordering_r, state.players[seat].tile_aliases)
      points = for yaku <- yaku_list, reduce: 0 do
        points when points >= min_points -> points
        points -> case get_yaku(state, [yaku], seat, assigned_winning_tile, win_source, minipoints) do
          []             -> points
          [{_name, pts}] -> points + pts
        end
      end
      points >= min_points
    end)
  end

  def seat_scores_points(state, yaku_list, min_points, seat, winning_tile, win_source) do
    yaku_names = Enum.map(yaku_list, fn yaku -> yaku["display_name"] end)
    case RiichiAdvanced.ETSCache.get({:seat_scores_points, state.players[seat].hand, state.players[seat].calls, winning_tile, state.players[seat].tile_aliases, yaku_names, min_points}) do
      [] -> 
        result = _seat_scores_points(state, yaku_list, min_points, seat, winning_tile, win_source)
        RiichiAdvanced.ETSCache.put({:seat_scores_points, state.players[seat].hand, state.players[seat].calls, winning_tile, state.players[seat].tile_aliases, yaku_names, min_points}, result)
        result
      [result] -> result
    end
  end

  defp parse_test_spec(rules, test_spec) do
    name = test_spec["name"]
    hand = if Map.has_key?(test_spec, "hand") do Enum.map(test_spec["hand"], &Utils.to_tile/1) else [] end
    calls = if Map.has_key?(test_spec, "calls") do Enum.map(test_spec["calls"], fn [call_name, call_tiles] -> {call_name, Enum.map(call_tiles, fn tile -> {Utils.to_tile(tile), false} end)} end ) else [] end
    status = test_spec["status"]
    conditions = if Map.has_key?(test_spec, "conditions") do test_spec["conditions"] else [] end
    winning_tile = if Map.has_key?(test_spec, "winning_tile") do Utils.to_tile(test_spec["winning_tile"]) else
        GenServer.cast(self(), {:show_error, "Could not find key \"winning_tile\" in test spec:\n#{inspect(test_spec)}"})
      end
    win_source = case test_spec["win_source"] do
        "draw"    -> :draw
        "call"    -> :call
        "discard" -> :discard
        nil       -> GenServer.cast(self(), {:show_error, "Could not find key \"win_source\" in test spec:\n#{inspect(test_spec)}"})
        _         -> GenServer.cast(self(), {:show_error, "\"win_source\" should be one of \"discard\", \"call\", or \"draw\" in test spec:\n#{inspect(test_spec)}"})
      end
    kyoku = if is_integer(test_spec["round"]) do test_spec["round"] else 0 end
    seat = case test_spec["seat"] do 
        "south" -> Utils.next_turn(:south, kyoku)
        "west"  -> Utils.next_turn(:west, kyoku)
        "north" -> Utils.next_turn(:north, kyoku)
        _       -> Utils.next_turn(:east, kyoku)
      end
    yaku_list = case test_spec["yaku_lists"] do
        nil        -> GenServer.cast(self(), {:show_error, "Could not find key \"yaku_lists\" in test spec:\n#{inspect(test_spec)}"})
        yaku_lists ->
          Enum.flat_map(yaku_lists, fn list_name ->
            if Map.has_key?(rules, list_name) do
              rules[list_name]
            else
              GenServer.cast(self(), {:show_error, "Could not find yaku list \"#{list_name}\" in ruleset!"})
              []
            end
          end)
      end
    expected_yaku = case test_spec["expected_yaku"] do
        nil           -> GenServer.cast(self(), {:show_error, "Could not find key \"expected_yaku\" in test spec:\n#{inspect(test_spec)}"})
        expected_yaku -> Enum.map(expected_yaku, fn [name, value] -> {name, value} end)
      end

    {name, hand, calls, status, conditions, winning_tile, win_source, kyoku, seat, yaku_list, expected_yaku}
  end

  def run_yaku_tests(state) do
    if Map.has_key?(state.rules, "yaku_tests") && Map.has_key?(state.rules, "run_yaku_tests") && state.rules["run_yaku_tests"] do
      for test_spec <- state.rules["yaku_tests"] do
        {name, hand, calls, status, conditions, winning_tile, win_source, kyoku, seat, yaku_list, expected_yaku} = parse_test_spec(state.rules, test_spec)

        # setup a state where a given player has the given hand, calls, and tiles
        minipoints = if state.rules["score_calculation"]["method"] == "riichi" do
            Riichi.calculate_fu(hand, calls, winning_tile, win_source, Riichi.get_seat_wind(kyoku, seat), Riichi.get_round_wind(kyoku), state.players.east.tile_ordering, state.players.east.tile_ordering_r)
          else 0 end
        state = state
          |> update_player(seat, &%Player{ &1 | hand: hand, calls: calls, status: if status == nil do &1.status else status end })
          |> Map.put(:kyoku, kyoku)
        state = for condition <- conditions, reduce: state do
          state -> case condition do
            "make_discards_exist" -> update_action(state, seat, :discard, %{tile: :"1x"}) 
            "no_draws_remaining"  -> Map.put(state, :wall_index, length(state.wall))
            _ ->
              GenServer.cast(self(), {:show_error, "Unknown test condition #{inspect(condition)} in yaku test #{name}"})
              state
          end
        end
        yaku = get_yaku(state, yaku_list, seat, winning_tile, win_source, minipoints)
        # IO.puts("Got yaku: #{inspect(yaku)}")
        # IO.puts("Expected yaku: #{inspect(expected_yaku)}")
        if yaku != expected_yaku do
          GenServer.cast(self(), {:show_error, "Yaku test #{name} failed!\n  Got yaku: #{inspect(yaku)}\n  Expected yaku: #{inspect(expected_yaku)}"})
        end
      end
    end
  end

  def score_yaku(state, seat, yaku, yakuman, is_dealer, is_self_draw, minipoints \\ 0, opponents_remaining \\ 3) do
    scoring_table = state.rules["score_calculation"]
    case scoring_table["method"] do
      "riichi" ->
        points = Enum.reduce(yaku, 0, fn {_name, value}, acc -> acc + value end)
        yakuman_mult = Enum.reduce(yakuman, 0, fn {_name, value}, acc -> acc + value end)

        # handle ryuumonbuchi touka's scoring quirk
        new_points = if "score_limit_one_tier_higher" in state.players[seat].status do
          case points do
            3 when minipoints >= 70 -> 6
            4 when minipoints >= 40 -> 6
            5 -> 6
            6 -> 8
            7 -> 8
            8 -> 11
            9 -> 11
            10 -> 11
            11 -> 13
            12 -> 13
            _ -> points
          end
        else points end
        if new_points > points do
          push_message(state, [%{text: "Player #{seat} #{state.players[seat].nickname} scores their limit hand one tier higher (Ryuumonbuchi Touka)"}])
        end
        points = new_points

        han = Integer.to_string(points)
        fu = Integer.to_string(minipoints)
        oya_han_table = if is_self_draw do scoring_table["score_table_dealer_draw"] else scoring_table["score_table_dealer"] end
        ko_han_table = if is_self_draw do scoring_table["score_table_nondealer_draw"] else scoring_table["score_table_nondealer"] end
        oya_fu_table = if yakuman_mult > 0 do oya_han_table["max"] else Map.get(oya_han_table, han, oya_han_table["max"]) end
        ko_fu_table = if yakuman_mult > 0 do ko_han_table["max"] else Map.get(ko_han_table, han, ko_han_table["max"]) end

        score = if yakuman_mult == 0 do
          if is_self_draw do
            if is_dealer do
              3 * Map.get(oya_fu_table, fu, oya_fu_table["max"])
            else
              Map.get(oya_fu_table, fu, oya_fu_table["max"]) + 2 * Map.get(ko_fu_table, fu, ko_fu_table["max"])
            end
          else
            if is_dealer do
              Map.get(oya_fu_table, fu, oya_fu_table["max"])
            else
              Map.get(ko_fu_table, fu, ko_fu_table["max"])
            end
          end
        else
          if is_self_draw do
            if is_dealer do
              yakuman_mult * 3 * oya_fu_table["max"]
            else
              yakuman_mult * (oya_fu_table["max"] + 2 * ko_fu_table["max"])
            end
          else
            if is_dealer do
              yakuman_mult * oya_fu_table["max"]
            else
              yakuman_mult * ko_fu_table["max"]
            end
          end
        end

        score = if "double_score" in state.players[seat].status do score * 2 else score end

        {score, points, yakuman_mult}
      "hk" ->
        points = Enum.reduce(yaku, 0, fn {_name, value}, acc -> acc + value end)
        fan = Integer.to_string(points)

        dealer_fan_table = if is_self_draw do scoring_table["score_table_dealer_draw"] else scoring_table["score_table_dealer"] end
        nondealer_fan_table = if is_self_draw do scoring_table["score_table_nondealer_draw"] else scoring_table["score_table_nondealer"] end
        dealer_payment = Map.get(dealer_fan_table, fan, dealer_fan_table["max"])
        nondealer_payment = Map.get(nondealer_fan_table, fan, nondealer_fan_table["max"])
        payment = if is_dealer do dealer_payment else nondealer_payment end

        score = payment * if is_self_draw do 3 else 4 end

        {score, points, 0}
      "sichuan" ->
        points = Enum.reduce(yaku, 0, fn {_name, value}, acc -> acc + value end)
        fan = Integer.to_string(points)

        fan_table = scoring_table[if is_self_draw do "score_table_draw" else "score_table" end]
        score = Map.get(fan_table, fan, fan_table["max"])
        score = if is_self_draw do opponents_remaining * score else score end
        {score, points, 0}
      "vietnamese" ->
        phan = Enum.reduce(yaku, 0, fn {_name, value}, acc -> acc + value end)
        mun = Enum.reduce(yakuman, 0, fn {_name, value}, acc -> acc + value end)
        mun = mun + Integer.floor_div(phan, 6)
        phan = rem(phan, 6)
        phan_table_discarder = scoring_table["score_table_phan_discarder"]
        phan_table_non_discarder = scoring_table["score_table_phan_non_discarder"]
        score_discarder = if mun == 0 do phan_table_discarder[Integer.to_string(phan)] else mun * phan_table_discarder["max"] end
        score_non_discarder = if mun == 0 do phan_table_non_discarder[Integer.to_string(phan)] else mun * phan_table_non_discarder["max"] end
        # IO.inspect(score_discarder)
        # IO.inspect(score_non_discarder)
        score = if is_self_draw do 3 * score_discarder else score_discarder + 2 * score_non_discarder end
        {score, phan, mun}
      _ ->
        GenServer.cast(self(), {:show_error, "Unknown scoring method #{inspect(scoring_table["method"])}"})
        {0, 0, 0}
    end
  end

  defp calculate_delta_scores_for_single_winner(state, winner, collect_sticks) do
    scoring_table = state.rules["score_calculation"]
    delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
    case scoring_table["method"] do
      "riichi" ->
        is_dealer = Riichi.get_east_player_seat(state.kyoku) == winner.seat

        # handle ryuumonbuchi touka's scoring quirk
        is_dealer = is_dealer || "score_as_dealer" in state.players[winner.seat].status

        {pao_yakuman, non_pao_yakuman} = Enum.split_with(winner.yakuman, fn {name, _value} -> name == "Daisangen" || name == "Daisuushii" end)
        if winner.pao_seat != nil && length(pao_yakuman) > 0 && length(non_pao_yakuman) > 0 do
          # split the calculation if both pao and non-pao yakuman exist
          {basic_score_pao, _, _} = score_yaku(state, winner.seat, [], pao_yakuman, is_dealer, winner.win_source == :draw, winner.minipoints)
          {basic_score_non_pao, _, _} = score_yaku(state, winner.seat, [], non_pao_yakuman, is_dealer, winner.win_source == :draw, winner.minipoints)
          delta_scores_pao = calculate_delta_scores_for_single_winner(state, %{ winner | score: basic_score_pao, yakuman: pao_yakuman }, collect_sticks)
          delta_scores_non_pao = calculate_delta_scores_for_single_winner(state, %{ winner | score: basic_score_non_pao, yakuman: non_pao_yakuman }, collect_sticks)
          delta_scores = Map.new(delta_scores_pao, fn {seat, delta} -> {seat, delta + delta_scores_non_pao[seat]} end)
          delta_scores
        else
          {riichi_payment, honba_payment} = if collect_sticks do
            riichi_payment = state.pot
            honba_payment = scoring_table["honba_value"] * state.honba
            {riichi_payment, honba_payment}
          else
            {0, 0}
          end

          winner_player = state.players[winner.seat]
          honba_payment = if "multiply_honba_with_han" in winner_player.status do honba_payment * winner.points else honba_payment end
          honba_payment = if "triple_noten_payments" in winner_player.status do honba_payment * 3 else honba_payment end

          # calculate some parameters that change if pao exists
          {delta_scores, basic_score, payer, direct_hit} =
            # due to the way we handle mixed pao-and-not-pao yakuman earlier,
            # we're guaranteed either all of the yakuman are pao, or none of them are
            if winner.pao_seat != nil && length(pao_yakuman) > 0 do
              # if pao, then payer becomes the pao seat,
              # and a ron payment is split in half
              if winner.payer != nil do # ron
                # the deal-in player is not responsible for honba payments,
                # so we take care of their share of payment right here
                basic_score = trunc(winner.score / 2)
                delta_scores = Map.put(delta_scores, winner.payer, -basic_score)
                delta_scores = Map.put(delta_scores, winner.seat, basic_score)
                {delta_scores, basic_score, winner.pao_seat, true}
              else
                {delta_scores, winner.score, winner.pao_seat, true}
              end
            else
              {delta_scores, winner.score, winner.payer, winner.payer != nil}
            end

          delta_scores = if direct_hit do
            # either ron, or tsumo pao, or remaining ron pao payment
            delta_scores = Map.update!(delta_scores, payer, & &1 - basic_score - honba_payment * 3)
            delta_scores = Map.update!(delta_scores, winner.seat, & &1 + basic_score + honba_payment * 3 + riichi_payment)
            delta_scores
          else
            # first give the winner their riichi sticks
            delta_scores = Map.update!(delta_scores, winner.seat, & &1 + riichi_payment)
            
            # reverse-calculate the ko and oya parts of the total points
            {ko_payment, oya_payment} = Riichi.calc_ko_oya_points(basic_score, is_dealer)

            # handle motouchi naruka's scoring quirk
            motouchi_naruka_delta = 100 * Integer.floor_div(state.pot, scoring_table["riichi_value"])
            {ko_payment, oya_payment} = if "motouchi_naruka_increase_tsumo_payment" in state.players[winner.seat].status do
              push_message(state, [%{text: "Player #{winner.seat} #{state.players[winner.seat].nickname} has tsumo payments increased by 300 per 1000 bet (#{3 * motouchi_naruka_delta}) (Motouchi Naruka)"}])
              {ko_payment + motouchi_naruka_delta, oya_payment + motouchi_naruka_delta}
            else {ko_payment, oya_payment} end
            {ko_payment, oya_payment} = if "motouchi_naruka_decrease_tsumo_payment" in state.players[winner.seat].status do
              push_message(state, [%{text: "Player #{winner.seat} #{state.players[winner.seat].nickname} has tsumo payments decreased by 300 per 1000 bet (#{3 * motouchi_naruka_delta}) (Motouchi Naruka)"}])
              {max(0, ko_payment - motouchi_naruka_delta), max(0, oya_payment - motouchi_naruka_delta)}
            else {ko_payment, oya_payment} end

            # have each payer pay their allotted share
            dealer_seat = Riichi.get_east_player_seat(state.kyoku)
            for payer <- [:east, :south, :west, :north] -- [winner.seat], reduce: delta_scores do
              delta_scores ->
                payment = if payer == dealer_seat do oya_payment else ko_payment end
                payment = if "atago_hiroe_no_tsumo_payment" in state.players[payer].status do
                  push_message(state, [%{text: "Player #{payer} #{state.players[payer].nickname} is damaten, and immune to tsumo payments (Atago Hiroe)"}])
                  0
                else payment end
                payment = if "double_tsumo_payment" in state.players[payer].status do
                  push_message(state, [%{text: "Player #{payer} #{state.players[payer].nickname} pays double for tsumo (Maya Yukiko)"}])
                  payment * 2
                else payment end
                delta_scores = Map.update!(delta_scores, payer, & &1 - payment - honba_payment)
                delta_scores = Map.update!(delta_scores, winner.seat, & &1 + payment + honba_payment)
                delta_scores
            end
          end

          # handle arakawa kei's scoring quirk
          delta_scores = if "use_arakawa_kei_scoring" in winner_player.status do
            hand = winner_player.hand
            calls = winner_player.calls
            win_definitions = translate_match_definitions(state, ["win"])
            ordering = winner_player.tile_ordering
            ordering_r = winner_player.tile_ordering_r
            tile_aliases = winner_player.tile_aliases
            visible_ponds = Enum.flat_map(state.players, fn {_seat, player} -> player.pond end)
            visible_calls = Enum.flat_map(state.players, fn {_seat, player} -> player.calls end)
            visible_tiles = hand ++ visible_ponds ++ Enum.flat_map(visible_calls, &Riichi.call_to_tiles/1)
            waits = Riichi.get_waits_and_ukeire(state.all_tiles, visible_tiles, hand, calls, win_definitions, ordering, ordering_r, tile_aliases)
            if "arakawa-kei" in winner_player.status do
              # everyone pays winner 100 points per live out
              ukeire = waits |> Map.values() |> Enum.sum()
              push_message(state, [%{text: "Everybody pays player #{winner.seat} #{state.players[winner.seat].nickname} #{100 * ukeire} for #{ukeire} live out(s) (Arakawa Kei)"}])
              delta_scores
              |> Map.new(fn {seat, score} -> {seat, score - 100 * ukeire} end)
              |> Map.update!(winner.seat, & &1 + 400 * ukeire)
            else
              # winner pays arakawa kei 1000 points per waiting tile in her hand
              {arakawa_kei_seat, arakawa_kei} = Enum.find(state.players, fn {_seat, player} -> "arakawa-kei" in player.status end)
              waiting_tiles = Map.keys(waits)
              num = Utils.count_tiles(arakawa_kei.hand, waiting_tiles)
              push_message(state, [%{text: "Winner pays player #{arakawa_kei_seat} #{state.players[arakawa_kei_seat].nickname} #{1000 * num} for having #{num} wait(s) in hand (Arakawa Kei)"}])
              delta_scores
              |> Map.update!(winner.seat, & &1 - 1000 * num)
              |> Map.update!(arakawa_kei_seat, & &1 + 1000 * num)
            end
          else delta_scores end

          delta_scores
        end
      "hk" ->
        self_pick = winner.payer == nil
        basic_score = trunc(winner.score / if self_pick do 3 else 4 end)
        payer_seat = winner.payer
        for payer <- [:east, :south, :west, :north] -- [winner.seat], reduce: delta_scores do
          delta_scores ->
            payment = if payer == payer_seat do 2 * basic_score else basic_score end
            delta_scores = Map.update!(delta_scores, payer, & &1 - payment)
            delta_scores = Map.update!(delta_scores, winner.seat, & &1 + payment)
            delta_scores
        end
      "sichuan" ->
        # two cases: for a normal win, use winner.payer. for draws, use winner.payers
        payers = if Map.has_key?(winner, :payer) do [winner.payer] else winner.payers end
        for payer <- payers, reduce: delta_scores do
          delta_scores ->
            if payer != nil do
                delta_scores = Map.update!(delta_scores, payer, & &1 - winner.score)
                delta_scores = Map.update!(delta_scores, winner.seat, & &1 + winner.score)
                delta_scores
            else
              payment = trunc(winner.score / length(winner.opponents))
              for payer <- winner.opponents, reduce: delta_scores do
                delta_scores ->
                  delta_scores = Map.update!(delta_scores, payer, & &1 - payment)
                  delta_scores = Map.update!(delta_scores, winner.seat, & &1 + payment)
                  delta_scores
              end
            end
        end
      "vietnamese" ->
        # same as hk, i think
        self_pick = winner.payer == nil
        basic_score = trunc(winner.score / if self_pick do 3 else 4 end)
        payer_seat = winner.payer
        for payer <- [:east, :south, :west, :north] -- [winner.seat], reduce: delta_scores do
          delta_scores ->
            payment = if payer == payer_seat do 2 * basic_score else basic_score end
            delta_scores = Map.update!(delta_scores, payer, & &1 - payment)
            delta_scores = Map.update!(delta_scores, winner.seat, & &1 + payment)
            delta_scores
        end
      _ ->
        GenServer.cast(self(), {:show_error, "Unknown scoring method #{inspect(scoring_table["method"])}"})
        delta_scores
    end
  end

  defp calculate_delta_scores(state, delta_scores) do
    scoring_table = state.rules["score_calculation"]
    closest_winner = case scoring_table["method"] do
      "riichi" ->
        # determine the closest winner (the one who receives riichi sticks and honba)
        {_seat, some_winner} = Enum.at(state.winners, 0)
        payer = some_winner.payer
        if payer == nil do some_winner.seat else
          next_seat_1 = if state.reversed_turn_order do Utils.prev_turn(payer) else Utils.next_turn(payer) end
          next_seat_2 = if state.reversed_turn_order do Utils.prev_turn(next_seat_1) else Utils.next_turn(next_seat_1) end
          next_seat_3 = if state.reversed_turn_order do Utils.prev_turn(next_seat_2) else Utils.next_turn(next_seat_2) end
          next_seat_4 = if state.reversed_turn_order do Utils.prev_turn(next_seat_3) else Utils.next_turn(next_seat_3) end
          cond do
            Map.has_key?(state.winners, next_seat_1) -> next_seat_1
            Map.has_key?(state.winners, next_seat_2) -> next_seat_2
            Map.has_key?(state.winners, next_seat_3) -> next_seat_3
            Map.has_key?(state.winners, next_seat_4) -> next_seat_4
          end
        end
      _ -> nil
    end

    # sum the individual delta scores for each winner, skipping winners already marked as processed
    for {seat, winner} <- state.winners, not Map.has_key?(winner, :processed), reduce: delta_scores do
      delta_scores_acc ->
        delta_scores = calculate_delta_scores_for_single_winner(state, winner, seat == closest_winner)
        delta_scores_acc = Map.new(delta_scores_acc, fn {seat, delta} -> {seat, delta + delta_scores[seat]} end)
        delta_scores_acc
    end
  end
  
  def adjudicate_win_scoring(state) do
    scoring_table = state.rules["score_calculation"]
    delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
    {state, delta_scores, delta_scores_reason, next_dealer} = case scoring_table["method"] do
      "riichi" ->
        # handle nelly virsaladze's scoring quirk
        {state, delta_scores} = for {seat, player} <- state.players, reduce: {state, delta_scores} do
          {state, delta_scores} ->
            if "nelly_virsaladze_take_bets" in player.status do
              push_message(state, [%{text: "Player #{seat} #{state.players[seat].nickname} takes all bets on the table (#{state.pot}) and is paid 1500 by every player (Nelly Virsaladze)"}])
              delta_scores = Map.update!(delta_scores, seat, & &1 + state.pot + 4500)
              delta_scores = for {dir, _player} <- state.players, dir != seat, reduce: delta_scores do
                delta_scores -> Map.update!(delta_scores, dir, & &1 - 1500)
              end
              state = Map.put(state, :pot, 0)
              {state, delta_scores}
            else {state, delta_scores} end
        end
        
        delta_scores = calculate_delta_scores(state, delta_scores)

        {_seat, some_winner} = Enum.at(state.winners, 0)
        delta_scores_reason = cond do
          some_winner.pao_seat != nil  -> "Sekinin Barai"
          map_size(state.winners) == 1 ->
            {_seat, winner} = Enum.at(state.winners, 0)
            if winner.payer == nil do "Tsumo" else "Ron" end
          map_size(state.winners) == 2 -> "Double Ron"
          map_size(state.winners) == 3 -> "Triple Ron"
        end

        {state, delta_scores, delta_scores_reason} = if Map.get(scoring_table, "triple_ron_draw", false) && map_size(state.winners) == 3 do
          state = Map.put(state, :winners, %{})
          delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
          delta_scores_reason = "Sanchahou"
          {state, delta_scores, delta_scores_reason}
        else {state, delta_scores, delta_scores_reason} end

        next_dealer = if Map.has_key?(state.winners, Riichi.get_east_player_seat(state.kyoku)) do :self else :shimocha end
        {state, delta_scores, delta_scores_reason, next_dealer}
      "hk" ->
        delta_scores = calculate_delta_scores(state, delta_scores)
        {_seat, winner} = Enum.at(state.winners, 0)
        delta_scores_reason = cond do
            winner.payer == nil          -> "Zimo"
            map_size(state.winners) == 1 -> "Hu"
            map_size(state.winners) == 2 -> "Double Hu"
            map_size(state.winners) == 3 -> "Triple Hu"
          end
        {state, delta_scores, delta_scores_reason, :shimocha}
      "sichuan" ->
        # this will be called after every hu/double hu/triple hu
        # this function will calculate the next dealer every time,
        # but only the first result will be used

        delta_scores = calculate_delta_scores(state, delta_scores)
        winners = Enum.filter(state.winners, fn {_seat, winner} -> not Map.has_key?(winner, :processed) end)
        {_seat, winner} = Enum.at(state.winners, -1)
        has_payer = Map.has_key?(winner, :payer)
        delta_scores_reason = cond do
            not has_payer        -> "Draw"
            winner.payer == nil  -> "Zimo"
            length(winners) == 0 ->
              IO.puts("Error: last win was nobody? #{inspect(state.winners)}")
              "Hu"
            length(winners) == 1 -> "Hu"
            length(winners) == 2 -> "Double Hu"
            length(winners) == 3 -> "Triple Hu"
          end

        # the first winner becomes the next dealer
        # if there are multiple first winners, the payer becomes the next dealer
        {last_winner_seat, last_winner} = Enum.at(state.winners, map_size(state.winners)-1)
        next_dealer = if Map.has_key?(last_winner, :payer) do
          current_dealer = Riichi.get_east_player_seat(state.kyoku)
          new_dealer = if length(winners) >= 2 do last_winner.payer else last_winner_seat end
          Utils.get_relative_seat(current_dealer, new_dealer)
        else nil end # otherwise this winner is from a draw, ignore

        # mark all winners as processed
        state = Map.update!(state, :winners, &Map.new(&1, fn {seat, winner} -> {seat, Map.put(winner, :processed, true)} end))

        {state, delta_scores, delta_scores_reason, next_dealer}
      "vietnamese" ->
        delta_scores = calculate_delta_scores(state, delta_scores)
        {_seat, winner} = Enum.at(state.winners, 0)
        delta_scores_reason = cond do
            winner.payer == nil          -> "Tự ù"
            map_size(state.winners) == 1 -> "Ù"
            map_size(state.winners) == 2 -> "Double Ù"
            map_size(state.winners) == 3 -> "Triple Ù"
          end
        {state, delta_scores, delta_scores_reason, :shimocha}
      _ ->
        GenServer.cast(self(), {:show_error, "Unknown scoring method #{inspect(scoring_table["method"])}"})
        state = Map.update!(state, :kyoku, & &1 + 1)
        {state, delta_scores, "", :shimocha}
    end
    {state, delta_scores, delta_scores_reason, next_dealer}
  end

  def adjudicate_draw_scoring(state) do
    scoring_table = state.rules["score_calculation"]
    {state, delta_scores, delta_scores_reason, next_dealer} = case scoring_table["method"] do
      "riichi" ->
        tenpai = Map.new(state.players, fn {seat, player} -> {seat, "tenpai" in player.status} end)
        nagashi = Map.new(state.players, fn {seat, player} -> {seat, "nagashi" in player.status} end)
        num_tenpai = tenpai |> Map.values() |> Enum.count(& &1)
        num_nagashi = nagashi |> Map.values() |> Enum.count(& &1)
        {state, delta_scores} = if num_nagashi > 0 do
          scores_before = Map.new(state.players, fn {seat, player} -> {seat, player.score} end)
          state = for {seat, nagashi?} <- nagashi, nagashi?, payer <- [:east, :south, :west, :north] -- [seat], reduce: state do
            state ->
              oya_payment = 4000
              ko_payment = if Riichi.get_east_player_seat(state.kyoku) == seat do 4000 else 2000 end
              payment = if Riichi.get_east_player_seat(state.kyoku) == payer do oya_payment else ko_payment end
              state
                |> update_player(seat, &%Player{ &1 | score: &1.score + payment })
                |> update_player(payer, &%Player{ &1 | score: &1.score - payment })
          end
          delta_scores = Map.new(state.players, fn {seat, player} -> {seat, player.score - scores_before[seat]} end)
          {state, delta_scores}
        else
          delta_scores = case num_tenpai do
            0 -> Map.new(tenpai, fn {seat, _tenpai} -> {seat, 0} end)
            1 -> Map.new(tenpai, fn {seat, tenpai} -> {seat, if tenpai do 3000 else -1000 end} end)
            2 -> Map.new(tenpai, fn {seat, tenpai} -> {seat, if tenpai do 1500 else -1500 end} end)
            3 -> Map.new(tenpai, fn {seat, tenpai} -> {seat, if tenpai do 1000 else -3000 end} end)
            4 -> Map.new(tenpai, fn {seat, _tenpai} -> {seat, 0} end)
          end
          {state, delta_scores}
        end
        # reveal hand for those players that are tenpai or nagashi
        state = update_all_players(state, fn seat, player -> %Player{ player | hand_revealed: tenpai[seat] || nagashi[seat] } end)

        delta_scores_reason = cond do
          num_nagashi == 0 -> "Ryuukyoku"
          num_nagashi > 0  -> "Nagashi Mangan"
        end

        next_dealer = if tenpai[Riichi.get_east_player_seat(state.kyoku)] do :self else :shimocha end

        {state, delta_scores, delta_scores_reason, next_dealer}
      "hk" ->
        delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
        delta_scores_reason = "Draw"
        {state, delta_scores, delta_scores_reason, false}
      "sichuan" ->
        delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
        delta_scores_reason = "Draw"

        # declare tenpai players as winners, as if they won from non-tenpai people
        winners = Map.keys(state.winners)
        tenpai = Map.new(state.players, fn {seat, player} -> {seat, "tenpai" in player.status} end)
        payers = Enum.flat_map(tenpai, fn {seat, tenpai?} -> if not tenpai? do [seat] else [] end end)

        state = if Map.get(scoring_table, "draw_payments", false) do
          # for each tenpai player who hasn't won, find the highest point hand they could get
          win_definitions = translate_match_definitions(state, ["win"])
          for {seat, tenpai?} <- tenpai, tenpai?, seat not in winners, reduce: state do
            state ->
              ordering = state.players[seat].ordering
              ordering_r = state.players[seat].ordering_r
              tile_aliases = state.players[seat].tile_aliases
              hand = state.players[seat].hand
              calls = state.players[seat].calls
              waits = Riichi.get_waits(hand, calls, win_definitions, ordering, ordering_r, tile_aliases) ++ [:"2x"]
              state2 = Map.put(state, :wall_index, 0) # use this so under the sea isn't scored
              {winning_tile, best_yaku} = for winning_tile <- waits do
                possible_yaku = get_yaku(state2, state.rules["yaku"], seat, winning_tile, :discard)
                {winning_tile, possible_yaku}
              end |> Enum.max_by(fn {_winning_tile, possible_yaku} -> Enum.reduce(possible_yaku, 0, fn {_name, value}, acc -> acc + value end) end)
              is_dealer = Riichi.get_east_player_seat(state.kyoku) == seat
              {score, points, _} = score_yaku(state, seat, best_yaku, [], is_dealer, false)
              call_tiles = Enum.flat_map(state.players[seat].calls, &Riichi.call_to_tiles/1)
              winning_hand = state.players[seat].hand ++ call_tiles ++ [winning_tile]
              winner = %{
                seat: seat,
                player: state.players[seat],
                winning_hand: winning_hand,
                winning_tile: winning_tile,
                winning_tile_text: "",
                win_source: :discard,
                point_name: state.rules["point_name"],
                yaku: best_yaku,
                yakuman: [],
                points: points,
                score: score,
                payers: payers
              }
              state = Map.update!(state, :winners, &Map.put(&1, seat, winner))
              state
          end
        else state end

        state = if Enum.any?(state.winners, fn {_seat, winner} -> not Map.has_key?(winner, :processed) end) do
          Map.put(state, :visible_screen, :winner)
        else
          Map.put(state, :visible_screen, :scores)
        end
        state = Map.put(state, :round_result, :draw)

        # reveal hand for those players that are tenpai
        state = update_all_players(state, fn seat, player -> %Player{ player | hand_revealed: tenpai[seat] } end)
        
        next_dealer = if state.next_dealer != nil do state.next_dealer else :shimocha end
        {state, delta_scores, delta_scores_reason, next_dealer}
      "vietnamese" ->
        delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
        state = Map.update!(state, :kyoku, & &1 + 1)
        {state, delta_scores, "", false}
      _ ->
        GenServer.cast(self(), {:show_error, "Unknown scoring method #{inspect(scoring_table["method"])}"})
        delta_scores = Map.new(state.players, fn {seat, _player} -> {seat, 0} end)
        state = Map.update!(state, :kyoku, & &1 + 1)
        {state, delta_scores, "", false}
    end
    {state, delta_scores, delta_scores_reason, next_dealer}
  end

end
