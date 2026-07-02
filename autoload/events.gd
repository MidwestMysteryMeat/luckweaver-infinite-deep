extends Node
## Events — global signal bus. Autoload (first, so everyone can connect in _ready).

# Session flow
signal lobby_changed
signal run_started
signal floor_loaded(fnum: int)
signal left_game
signal net_error(msg: String)

# Player state
signal players_changed
signal my_record_changed

# Encounters (gambling combat)
signal enc_state(state: Dictionary)

# UI / feedback
signal notify(text: String)
signal chat_line(who: String, text: String)
signal open_bench(kind: String)
signal chest_contents(key: String, items: Array)
