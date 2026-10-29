extends Node2D
## 1曲のリズムゲームの中で、ルアーアクション → アタリ → ファイトへ譜面が変化する釣りゲーム
##
##  ルアーアクション: タップのノーツ。決めるとルアーが動いてアピール値が上がる
##  アピール満タン → 譜面に「HIT!!」ラインが流れてくる（曲は止まらない）
##  ファイト       : スライドのラインをなぞる。テンションが上がると赤い帯（指を離す）が出る
##  釣れたら       : 同じ曲のままルアーアクションに戻り、連続で釣っていく
##  バラしたら     : テンション限界で糸が切れたらゲームオーバー（ばらさなければ継続）
## タイトル: ゲームスタート / 魚図鑑（釣った魚が記録され、端末に保存される）
## PC操作: マウス、または Space=押す・←→/A D=指の位置

enum State { TITLE, AREAS, DEX, WORLD, SPOTS, JOURNAL, SETTLEMENT, IDLE, CASTING, PLAY, GAMEOVER }

@export var areas: Array[AreaData] = []   ## 釣り場のリスト（data/areas/*.tres）
@export var music_offset := 0.0            ## 音ズレ補正（秒）。音が遅れて聞こえるなら + にする
@export_range(0.0, 1.0) var music_volume := 0.8
@export var clear_ratio := 0.7             ## 釣り上げに必要な達成率
@export_range(0.05, 0.3) var path_tolerance := 0.12  ## ラインの許容幅（画面幅に対する割合）

const WATER_Y := 400.0
const ROD_BASE := Vector2(150, 330)
const ROD_TIP := Vector2(290, 280)
const SIDE_MARGIN := 60.0
const FALL := 600.0        # 落ちる距離(px)
const PERFECT_W := 0.07
const GOOD_W := 0.14
const GRACE := 0.15        # 切り替え直後の猶予(秒)
const MUSIC_VARIANTS := 2   # エリアごとの曲数（audio/<ID>_1_*.ogg, _2_*.ogg）
const SAVE_PATH := "user://save.json"
const RANK_VALUE := {"B": 1, "A": 2, "S": 3}
const PART_BEATS := 16.0  # 4小節 (4/4) を最後まで演奏する
const SETTLEMENTS := [
	{"name": "潮風村", "kind": "村", "chapter": 0, "intro": "旅の始まり。師匠が釣りの基本を教えてくれる。", "tip": "港の釣り座で依頼を進めよう。"},
	{"name": "清流町", "kind": "町", "chapter": 3, "intro": "川沿いの宿場町。釣り人と旅人が集う。", "tip": "上流・中流の魚を図鑑に登録しよう。"},
	{"name": "水都みなと市", "kind": "市", "chapter": 6, "intro": "市場と運河を抱えた大きな水辺の都市。", "tip": "難しい水域に備えてリズムを磨こう。"}
]
# ルアーアクションのタップ位置（8分音符×8 = 1小節）
# ルアーアクションのタップ位置（8分音符×8 = 1小節）。エリアの lure_style で選ぶ
const LURE_SETS := [
	[   # 0: のんびり
		[1, 0, 0, 0, 1, 0, 0, 0],
		[1, 0, 0, 0, 1, 0, 1, 0],
		[1, 0, 0, 1, 0, 0, 0, 0],
	],
	[   # 1: ふつう
		[1, 0, 1, 0, 1, 0, 0, 0],
		[1, 0, 0, 1, 0, 0, 1, 0],
		[1, 1, 0, 0, 1, 0, 0, 0],
		[1, 0, 1, 1, 0, 0, 1, 0],
	],
	[   # 2: せわしない
		[1, 0, 1, 1, 0, 1, 1, 0],
		[1, 1, 0, 1, 1, 0, 1, 0],
		[1, 0, 1, 0, 1, 1, 0, 1],
	],
]

const Journey = preload("res://scripts/journey_data.gd")
var chapter := 0
var quest_count := 0
var spot_index := 0
var story_catches: Dictionary = {}
var state: State = State.TITLE
var font: Font
var time := 0.0
var timer := 0.0

# 入力
var held := false
var jp := false
var jr := false
var finger_x := 0.5   # 指のx位置 0〜1

# キャスト
var charging := false
var charge_t := 0.0
var power := 0.0
var cast_t := 0.0
var cast_target := Vector2.ZERO
var bobber_pos := Vector2.ZERO
var reel_start := Vector2.ZERO

# 曲の進行
var song_t := 0.0
var beat_len := 0.5
var last_step := -1

# 譜面（生成しながら流れてくる）
var taps: Array = []       # {t, s} s: 0=未処理 1=PERFECT 2=GOOD 3=MISS
var slides: Array = []     # {t0, t1, pts(Vector2: x=時刻, y=位置)}
var releases: Array = []   # {t0, t1, viol, done}
var gen_beat := 0.0
var gen_mode := 0          # 0=ルアー譜面を生成中 1=ファイト譜面を生成中
var since_release := 0
var last_x := 0.5
var bite_queued := false
var bite_t := -1.0
var lure_part_start := 0.0
var fight_part_start := 0.0
var break_until := -1.0
var catch_size := 1.0
var settlement_index := 0

# 状態
var fighting := false
var appeal := 0.0
var lure_kick := 0.0
var flash_t := 0.0
var current_fish: FishData
var slide_seen := 0.0   # ラインが流れていた時間
var slide_on := 0.0     # そのうちライン上にいた時間
var prog_rate := 0.1
var progress := 0.0
var tension := 0.0
var rel_seen := 0
var rel_ok := 0
var em_cd := 0.0
var cur_target := -1.0
var cur_release := false
var on_path := false
var strained := false
var was_strained := false

var judge_text := ""
var judge_col := Color.WHITE
var judge_t := 0.0

var chain := 0          # 連続で釣った数（バラすまで続く）
var best_by_area: Dictionary = {}   # エリア名 -> ベスト釣果
var area: AreaData
var area_scroll := 0.0
var area_press := Vector2.ZERO
var bpm := 120
var mus_a: AudioStreamPlayer   # 土台（パッド・ベース・キック）
var mus_b: AudioStreamPlayer   # 盛り上げ（メロディ・ハイハット等）。ファイト中にフェードイン
var music_key := ""
var mix_b := 0.0
var lead := 1.4          # 譜面が降り始めてから判定ラインに着くまでの秒数（エリアで変わる）
var dex: Dictionary = {}   # 魚名 -> {count, best}
var dex_list: Array = []   # 図鑑の並び（売値の安い順）
var dex_scroll := 0.0
var menu_sel := 0
var go_t := 0.0
var over_fish := ""
var money := 0
var caught_total := 0
var message := ""
var msg_t := 0.0

var snd_kick: AudioStreamPlayer
var snd_tick: AudioStreamPlayer
var snd_hit: AudioStreamPlayer
var snd_perfect: AudioStreamPlayer
var snd_miss: AudioStreamPlayer


func _ready() -> void:
	randomize()
	font = ThemeDB.fallback_font
	beat_len = 60.0 / bpm
	if areas.is_empty():
		for p in ["harbor", "upstream", "midstream", "downstream", "estuary", "stream", "swamp", "pond", "lake", "paddy"]:
			areas.append(load("res://data/areas/%s.tres" % p))
	area = areas[0]
	_apply_area()
	for a in areas:
		for f in a.fish:
			if not dex_list.has(f):
				dex_list.append(f)
	dex_list.sort_custom(func(a, b): return a.price < b.price)
	_load_save()
	get_tree().quit_on_go_back = false
	bobber_pos = ROD_TIP
	snd_kick = _make_player(_make_tone(160.0, 45.0, 0.18, 0.9))
	snd_tick = _make_player(_make_tone(1800.0, 1800.0, 0.03, 0.2))
	snd_hit = _make_player(_make_tone(880.0, 1100.0, 0.07, 0.5))
	snd_perfect = _make_player(_make_tone(1320.0, 1760.0, 0.09, 0.5))
	snd_miss = _make_player(_make_tone(140.0, 70.0, 0.15, 0.5))
	mus_a = _make_player(null)
	mus_b = _make_player(null)
	_music_set("title")


# ---------------- サウンド（コードで生成） ----------------

func _make_tone(f0: float, f1: float, dur: float, vol: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var d := PackedByteArray()
	d.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		phase += TAU * lerpf(f0, f1, t) / rate
		d.encode_s16(i * 2, int(sin(phase) * (1.0 - t) * vol * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = d
	return w


func _make_player(stream: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	add_child(p)
	return p


# ---------------- BGM（audio/ のOGGをループ再生） ----------------

func _area_music_id() -> String:
	return area.music if area.music != "" else area.scenery


func _load_loop(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var st = load(path)
	if st is AudioStreamOggVorbis:
		st.loop = true
	return st


## 曲IDを指定して再生。restart=true なら同じ曲でも頭から（譜面と同期させたいとき）
func _music_set(id: String, restart := false) -> void:
	if not restart and id == "title" and music_key.begins_with("title_") and mus_a.playing:
		return
	var v := (randi() % MUSIC_VARIANTS) + 1
	var key := "%s_%d" % [id, v]
	var sa := _load_loop("res://audio/%s_a.ogg" % key)
	var sb := _load_loop("res://audio/%s_b.ogg" % key)
	music_key = key
	mus_a.stop()
	mus_b.stop()
	mus_a.stream = sa
	mus_b.stream = sb
	if sa == null:
		return
	mus_a.play()
	if sb != null:
		mus_b.play()


func _music_on() -> bool:
	return mus_a != null and mus_a.stream != null and mus_a.playing


## 場面に合わせて盛り上げレイヤーをフェード（ファイト中は全開、ルアー中はアピール値に応じて）
func _music_mix(delta: float) -> void:
	var target := 0.0
	match state:
		State.PLAY:
			target = 1.0 if fighting else 0.4 * appeal
		State.TITLE, State.AREAS, State.DEX:
			target = 0.8
		State.IDLE, State.CASTING:
			target = 0.5
	mix_b = move_toward(mix_b, target, delta * 1.5)
	var base_db := linear_to_db(maxf(music_volume, 0.0001))
	mus_a.volume_db = base_db
	mus_b.volume_db = base_db + linear_to_db(maxf(mix_b, 0.0001))


## 拍でキック。ファイト中だけ裏拍のチックが加わって曲が盛り上がる
func _metronome() -> void:
	if song_t < 0.0 or _music_on():
		return
	var step := floori(song_t / (beat_len * 0.5))
	if step != last_step:
		last_step = step
		if step % 2 == 0:
			snd_kick.play()
		elif fighting:
			snd_tick.play()


# ---------------- 入力 ----------------

func _x_to_norm(x: float) -> float:
	var w := get_viewport_rect().size.x
	return clampf((x - SIDE_MARGIN) / (w - SIDE_MARGIN * 2.0), 0.0, 1.0)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			_back_action()
			return
		if event.physical_keycode == KEY_UP or event.physical_keycode == KEY_DOWN:
			var d := -1 if event.physical_keycode == KEY_UP else 1
			if state == State.TITLE or state == State.GAMEOVER:
				menu_sel = 1 - menu_sel
				return
			if state == State.DEX or state == State.AREAS:
				_scroll_by(d * 100.0)
				return
	var p := -1
	if event is InputEventScreenTouch:
		finger_x = _x_to_norm(event.position.x)
		p = 1 if event.pressed else 0
		if event.pressed:
			if _ui_press(event.position):
				return
		elif state == State.AREAS:
			_area_release(event.position)
	elif event is InputEventScreenDrag:
		finger_x = _x_to_norm(event.position.x)
		_scroll_by(-event.relative.y)
	elif event is InputEventMouseMotion:
		if held:
			finger_x = _x_to_norm(event.position.x)
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_scroll_by(-event.relative.y)
	elif event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll_by(-80.0)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_by(80.0)
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		finger_x = _x_to_norm(event.position.x)
		p = 1 if event.pressed else 0
		if event.pressed:
			if _ui_press(event.position):
				return
		elif state == State.AREAS:
			_area_release(event.position)
	elif event is InputEventKey:
		if event.echo or (event.physical_keycode != KEY_SPACE and event.physical_keycode != KEY_ENTER):
			return
		p = 1 if event.pressed else 0
	elif event is InputEventJoypadButton:
		if event.button_index != JOY_BUTTON_A:
			return
		p = 1 if event.pressed else 0
	if p == 1 and not held:
		jp = true
		held = true
	elif p == 0 and held:
		jr = true
		held = false


func _scroll_by(dy: float) -> void:
	if state == State.DEX:
		dex_scroll += dy
	elif state == State.AREAS:
		area_scroll += dy


# ---------------- メニュー / 画面遷移 / セーブ ----------------

func _btn_rect(i: int, vp: Vector2, y0: float) -> Rect2:
	return Rect2(vp.x * 0.5 - 220.0, y0 + i * 140.0, 440.0, 110.0)


## 画面タップがUI（ボタン）に使われたら true。true のときゲーム側の入力にはしない
func _ui_press(pos: Vector2) -> bool:
	var vp := get_viewport_rect().size
	if state in [State.WORLD, State.SPOTS, State.JOURNAL, State.SETTLEMENT]:
		_journey_press(pos)
		return true
	match state:
		State.TITLE:
			for i in 2:
				if _btn_rect(i, vp, 700.0).has_point(pos):
					_title_action(i)
			return true
		State.AREAS:
			if Rect2(20, 20, 170, 70).has_point(pos):
				_go_title()
				return true
			area_press = pos
			return true
		State.DEX:
			if Rect2(20, 20, 170, 70).has_point(pos):
				_go_title()
				return true
			return false
		State.GAMEOVER:
			if go_t <= 0.0:
				for i in 2:
					if _btn_rect(i, vp, 760.0).has_point(pos):
						_gameover_action(i)
			return true
		_:
			if Rect2(vp.x - 190.0, 12.0, 170.0, 56.0).has_point(pos):
				_return_map()
				return true
	return false


func _title_action(i: int) -> void:
	if i == 0:
		state = State.WORLD
		area_scroll = 0.0
		area_press = Vector2(-9999, -9999)
	else:
		state = State.DEX
		dex_scroll = 0.0


## エリア選択：指をほとんど動かさずに離したらタップとみなして、そのエリアで開始
func _area_release(pos: Vector2) -> void:
	if pos.distance_to(area_press) > 25.0 or pos.y < 130.0:
		return
	for i in areas.size():
		var y := 130.0 + i * 190.0 - area_scroll
		if Rect2(30, y, get_viewport_rect().size.x - 60.0, 170).has_point(pos):
			area = areas[i]
			_apply_area()
			state = State.SPOTS
			spot_index = 0
			return


func _apply_area() -> void:
	bpm = area.bpm
	beat_len = 60.0 / bpm
	lead = area.lead


## ラインの許容幅。河口・湖では潮や風で伸び縮みする
func _tol() -> float:
	return path_tolerance * area.tol_scale * (1.0 + area.tide * sin(time * 0.6))


func _best() -> int:
	return int(best_by_area.get(area.area_name, 0))


func _update_best() -> void:
	if caught_total > _best():
		best_by_area[area.area_name] = caught_total


func _total_caught() -> int:
	var n := 0
	for k in dex:
		n += int(dex[k].get("count", 0))
	return n


func _habitat(f: FishData) -> String:
	var names: PackedStringArray = []
	for a in areas:
		if a.fish.has(f):
			names.append(a.area_name)
	return "・".join(names)


func _gameover_action(i: int) -> void:
	if i == 0:
		_restart()
	else:
		_return_map()


func _back_action() -> void:
	if state == State.SPOTS or state == State.JOURNAL or state == State.SETTLEMENT:
		state = State.WORLD
	elif state == State.WORLD:
		_go_title()
	elif state in [State.IDLE, State.CASTING, State.PLAY, State.GAMEOVER]:
		_return_map()
	elif state != State.TITLE:
		_go_title()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:   # Androidの戻るボタン
		if state == State.TITLE:
			get_tree().quit()
		else:
			_back_action()


func _reset_chart() -> void:
	taps.clear()
	slides.clear()
	releases.clear()
	fighting = false
	bite_queued = false
	bite_t = -1.0
	tension = 0.0
	progress = 0.0
	cur_target = -1.0
	cur_release = false


func _go_title() -> void:
	_update_best()
	_save()
	_reset_chart()
	_music_set("title")
	state = State.TITLE
	menu_sel = 0
	charging = false
	bobber_pos = ROD_TIP
	chain = 0


func _start_game() -> void:
	money = 0
	caught_total = 0
	chain = 0
	msg_t = 0.0
	judge_t = 0.0
	charging = false
	_reset_chart()
	bobber_pos = ROD_TIP
	message = "長押しで力をため、離して投げよう"
	state = State.IDLE


func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		chapter = clampi(int(data.get("chapter", 0)), 0, areas.size())
		quest_count = clampi(int(data.get("quest_count", 0)), 0, 2)
		var records = data.get("story_catches", {})
		if records is Dictionary:
			story_catches = records
		var d = data.get("dex", {})
		if d is Dictionary:
			dex = d
		var b = data.get("best", {})
		if b is Dictionary:
			best_by_area = b


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"dex": dex, "best": best_by_area, "chapter": chapter, "quest_count": quest_count, "story_catches": story_catches}))


func _dex_found() -> int:
	var n := 0
	for f in dex_list:
		if int(dex.get(f.fish_name, {}).get("count", 0)) > 0:
			n += 1
	return n


# ---------------- ゲーム進行 ----------------

func _process(delta: float) -> void:
	time += delta
	judge_t = maxf(judge_t - delta, 0.0)
	_music_mix(delta)
	var dir := int(Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D)) \
		- int(Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A))
	finger_x = clampf(finger_x + dir * 0.9 * delta, 0.0, 1.0)
	match state:
		State.TITLE:
			if jp:
				_title_action(menu_sel)
		State.DEX:
			dex_scroll = maxf(dex_scroll, 0.0)
		State.IDLE: _idle(delta)
		State.CASTING: _casting(delta)
		State.PLAY: _play(delta)
		State.GAMEOVER:
			go_t = maxf(go_t - delta, 0.0)
			if jp and go_t <= 0.0:
				_gameover_action(menu_sel)
	jp = false
	jr = false
	queue_redraw()


func _idle(delta: float) -> void:
	if jp:
		charging = true
		charge_t = 0.0
	if charging:
		charge_t += delta
		power = pingpong(charge_t * 1.2, 1.0)
		if jr:
			charging = false
			cast_target = Vector2(ROD_TIP.x + 40.0 + power * 260.0, WATER_Y + 120.0 + power * 650.0)
			reel_start = cast_target
			cast_t = 0.0
			state = State.CASTING
			message = ""


func _casting(delta: float) -> void:
	cast_t += delta / 0.6
	var t := minf(cast_t, 1.0)
	bobber_pos = ROD_TIP.lerp(cast_target, t) + Vector2(0, -sin(PI * t) * 150.0)
	if t >= 1.0:
		_start_play()


func _start_play() -> void:
	state = State.PLAY
	# 再生を始めてから耳に届くまでの遅れ（出力遅延）ぶん、譜面の時計を引いておく
	song_t = -(AudioServer.get_output_latency() + music_offset)
	_music_set(_area_music_id(), true)
	last_step = -1
	taps.clear()
	slides.clear()
	releases.clear()
	gen_beat = 2.0
	lure_part_start = gen_beat * beat_len
	fight_part_start = 0.0
	break_until = -1.0
	gen_mode = 0
	bite_queued = false
	bite_t = -1.0
	fighting = false
	appeal = 0.0
	tension = 0.0
	progress = 0.0
	bobber_pos = reel_start


# ---------------- 1曲のメインループ ----------------

func _play(delta: float) -> void:
	song_t += delta
	lure_kick = maxf(lure_kick - 4.0 * delta, 0.0)
	flash_t = maxf(flash_t - delta, 0.0)
	msg_t = maxf(msg_t - delta, 0.0)
	em_cd = maxf(em_cd - delta, 0.0)
	_generate()
	_metronome()
	if fighting:
		_fight_update(delta)
	elif break_until >= 0.0:
		if song_t >= break_until:
			break_until = -1.0
			lure_part_start = gen_beat * beat_len
		else:
			appeal = 0.0
	else:
		_lure_update(delta)
		if bite_t >= 0.0 and song_t >= bite_t:
			_begin_fight()
	if fighting:
		bobber_pos = ROD_TIP.lerp(reel_start, clampf(1.0 - progress, 0.0, 1.0)) + Vector2(0, 20)
	else:
		bobber_pos = reel_start
	taps = taps.filter(func(n): return song_t - float(n["t"]) < 1.0)


# ---- 譜面生成：曲は止めずに、先の譜面だけ状況に応じて作る ----

func _generate() -> void:
	while gen_beat * beat_len - song_t < lead + 1.0:
		if gen_mode == 0:
			if bite_queued and gen_beat * beat_len >= lure_part_start + PART_BEATS * beat_len:
				# HIT!! マーカーを置いて、その後ろからファイト譜面
				bite_t = gen_beat * beat_len
				gen_beat += 1.0
				gen_mode = 1
				last_x = 0.5
				since_release = 0
				bite_queued = false
			else:
				if break_until >= 0.0 and gen_beat * beat_len < break_until:
					gen_beat += 4.0
					continue
				var pats: Array = LURE_SETS[area.lure_style]
				var pat: Array = pats[randi() % pats.size()]
				for i in 8:
					if pat[i] == 1:
						taps.append({"t": (gen_beat + i * 0.5) * beat_len, "s": 0})
				gen_beat += 4.0
		else:
			_gen_fight_segment()


func _gen_fight_segment() -> void:
	var f := current_fish
	# 先に流れる譜面は「いまのテンション」で決まる。高ければ離す帯が早めに、長めに入る
	if since_release >= 1 and (since_release >= 2 or tension > 0.55):
		var r := maxf(snappedf(f.release_beats * area.release_scale * (1.0 + tension), 0.5), 0.5)
		releases.append({"t0": gen_beat * beat_len, "t1": (gen_beat + r) * beat_len, "viol": false, "done": false})
		gen_beat += r
		since_release = 0
	else:
		var dens := clampf(f.note_density * area.wobble_scale, 0.1, 1.2)
		var step_b := 1.0 if dens < 0.6 else 0.5
		var maxstep := minf(0.2 + 0.4 * dens, 0.5)
		var length := float(randi_range(2, 4))
		var pts := PackedVector2Array()
		var x := last_x
		pts.append(Vector2(gen_beat * beat_len, x))
		var b := 0.0
		while b < length - 0.001:
			b = minf(b + step_b, length)
			var nx := clampf(x + randf_range(-1.0, 1.0) * maxstep, 0.1, 0.9)
			if absf(nx - x) < 0.1:
				nx = clampf(x + (0.15 if x < 0.5 else -0.15), 0.1, 0.9)
			x = nx
			pts.append(Vector2((gen_beat + b) * beat_len, x))
		last_x = x
		slides.append({"t0": gen_beat * beat_len, "t1": (gen_beat + length) * beat_len, "pts": pts})
		gen_beat += length
		since_release += 1


func _slide_x(pts: PackedVector2Array, t: float) -> float:
	for i in range(pts.size() - 1):
		if t <= pts[i + 1].x:
			var a := pts[i]
			var b := pts[i + 1]
			var k := 0.0 if b.x == a.x else clampf((t - a.x) / (b.x - a.x), 0.0, 1.0)
			return lerpf(a.y, b.y, k)
	return pts[pts.size() - 1].y


# ---- ルアーアクション ----

func _lure_update(delta: float) -> void:
	var idle := not bite_queued and bite_t < 0.0
	if idle:
		appeal = minf(appeal + 0.01 * area.bite_rate * delta, 1.0)
	if jp:
		_lure_tap(idle)
	for n in taps:
		if n["s"] == 0 and song_t - float(n["t"]) > GOOD_W:
			n["s"] = 3
			if idle:
				appeal = maxf(appeal - 0.06, 0.0)
			_show_judge("MISS", Color(1, 0.4, 0.4))
			snd_miss.play()
	if idle and appeal >= 1.0 and gen_mode == 0:
		current_fish = _pick_fish()
		bite_queued = true
		_show_judge("何か来た…！", Color(1, 0.9, 0.3))


func _lure_tap(idle: bool) -> void:
	var best = null
	var best_dt := 999.0
	for n in taps:
		if n["s"] == 0:
			var dt := absf(song_t - float(n["t"]))
			if dt <= GOOD_W and dt < best_dt:
				best = n
				best_dt = dt
	if best == null:
		return  # 空打ちはペナルティなし
	lure_kick = 1.0
	if best_dt <= PERFECT_W:
		best["s"] = 1
		if idle:
			appeal = minf(appeal + 0.12 * area.bite_rate, 1.0)
		_show_judge("PERFECT", Color(1, 0.95, 0.3))
		snd_perfect.play()
	else:
		best["s"] = 2
		if idle:
			appeal = minf(appeal + 0.07 * area.bite_rate, 1.0)
		_show_judge("GOOD", Color(0.5, 1, 0.6))
		snd_hit.play()


# ---- ファイト：スライド中心。テンションで「指を離す」帯が出る ----

func _begin_fight() -> void:
	fighting = true
	fight_part_start = song_t
	progress = 0.0
	tension = 0.0
	slide_on = 0.0
	slide_seen = 0.0
	rel_ok = 0
	rel_seen = 0
	was_strained = false
	em_cd = 2.0
	flash_t = 0.7
	appeal = 0.0
	# 釣り上げに必要な「ライン上にいる時間」= beats × 0.7 × clear_ratio 拍ぶん
	prog_rate = 1.0 / (current_fish.beats * beat_len * 0.7 * clear_ratio)
	_show_judge("HIT!!", Color(1, 0.9, 0.3))
	snd_perfect.play()


func _fight_update(delta: float) -> void:
	var pull := current_fish.pull_strength * area.pull_scale * minf(1.0 + 0.06 * chain, 2.0)  # 連続するほど魚が強くなる
	var in_slide := false
	var slide_age := 0.0
	cur_target = -1.0
	cur_release = false
	for sl in slides:
		if song_t >= float(sl["t0"]) and song_t <= float(sl["t1"]):
			in_slide = true
			cur_target = _slide_x(sl["pts"], song_t)
			slide_age = song_t - float(sl["t0"])
			break
	if in_slide:
		slide_seen += delta
	var rel_age := 0.0
	for r in releases:
		if song_t >= float(r["t0"]) and song_t <= float(r["t1"]):
			cur_release = true
			rel_age = song_t - float(r["t0"])
			if held and rel_age > GRACE:
				r["viol"] = true
		elif song_t > float(r["t1"]) and not r["done"]:
			r["done"] = true
			rel_seen += 1
			if r["viol"]:
				_show_judge("HELD!", Color(1, 0.4, 0.4))
			else:
				rel_ok += 1
				_show_judge("RELEASE!", Color(0.5, 0.95, 1))
				snd_perfect.play()
	# テンションが限界近くなら、魚が急に暴れて「離せ」が即発動
	if not cur_release and tension > 0.8 and em_cd <= 0.0:
		releases.append({"t0": song_t, "t1": song_t + 0.8, "viol": false, "done": false})
		em_cd = 3.0
		cur_release = true
		rel_age = 0.0
		_show_judge("暴れてる！ 離せ！", Color(1, 0.5, 0.3))
		snd_miss.play()

	on_path = false
	strained = false
	var rate := 0.0
	if cur_release:
		if held and rel_age > GRACE:
			rate = 0.6 * pull
			strained = true
		else:
			rate = -0.3
	elif in_slide:
		if held:
			if absf(finger_x - cur_target) <= _tol():
				on_path = true
				rate = 0.15 * pull
				progress = minf(1.0, progress + prog_rate * delta)
				slide_on += delta
			else:
				rate = 0.35 * pull
				strained = true
		else:
			rate = -0.1
			if slide_age > GRACE:
				progress = maxf(progress - 0.3 * prog_rate * delta, 0.0)
	else:
		rate = 0.05 * pull if held else -0.2
	tension = maxf(tension + rate * delta, 0.0)
	if strained and not was_strained:
		snd_miss.play()
	was_strained = strained

	# バラし：テンションが限界に達したら糸が切れてゲームオーバー
	if tension >= 1.0:
		_game_over()
		return
	# 引き寄せが満タンになった瞬間に釣り上げ → すぐルアーのリズムへ戻る
	if progress >= 1.0 and song_t - fight_part_start >= PART_BEATS * beat_len:
		_catch()


func _catch() -> void:
	var acc := slide_on / maxf(slide_seen, 0.1)
	var rel := float(rel_ok) / maxi(rel_seen, 1)
	var score := 0.7 * acc + 0.3 * rel
	var rank := "S" if score >= 0.85 else ("A" if score >= 0.65 else "B")
	# 同じ魚種でも精度でサイズが変わる。B=小型、S=大型
	catch_size = snappedf(current_fish.size * (0.75 + 0.75 * clampf(score, 0.0, 1.0)), 0.01)
	chain += 1
	var mult := 1.0 + 0.5 * score + 0.1 * minf(chain - 1.0, 10.0)
	var gain := int(round(current_fish.price * mult))
	money += gain
	caught_total += 1
	var msg := "%s を釣った！ サイズ %.2f  ランク%s  +%d円" % [current_fish.fish_name, catch_size, rank, gain]
	if chain >= 2:
		msg += "  %d連続！" % chain
	var entry: Dictionary = dex.get(current_fish.fish_name, {})
	var old_count := int(entry.get("count", 0))
	entry["count"] = old_count + 1
	entry["best_size"] = maxf(float(entry.get("best_size", 0.0)), catch_size)
	if RANK_VALUE[rank] > RANK_VALUE.get(String(entry.get("best", "")), 0):
		entry["best"] = rank
	dex[current_fish.fish_name] = entry
	msg += _record_story_catch()
	_update_best()
	_save()
	if old_count == 0:
		msg += "  NEW! 図鑑登録"
	_fight_over(msg)


## 釣れたら、曲は止めず同じテンポのままルアーアクションへ戻る。連続で釣るほど次のアタリが早い
func _fight_over(msg: String) -> void:
	fighting = false
	message = msg
	msg_t = 2.5
	slides.clear()
	releases.clear()
	taps.clear()
	bite_t = -1.0
	bite_queued = false
	gen_mode = 0
	gen_beat = ceil(song_t / (4.0 * beat_len)) * 4.0 + 4.0
	break_until = gen_beat * beat_len
	lure_part_start = break_until
	appeal = 0.0
	progress = 0.0
	tension = 0.0
	cur_target = -1.0
	cur_release = false
	_show_judge("CATCH!", Color(1, 0.95, 0.3))


func _game_over() -> void:
	over_fish = current_fish.fish_name
	state = State.GAMEOVER
	go_t = 1.0
	fighting = false
	_update_best()
	menu_sel = 0
	_save()
	_music_set("title")
	slides.clear()
	releases.clear()
	taps.clear()
	snd_miss.play()


func _restart() -> void:
	money = 0
	caught_total = 0
	chain = 0
	message = ""
	msg_t = 0.0
	judge_t = 0.0
	_start_play()


func _show_judge(t: String, c: Color) -> void:
	judge_text = t
	judge_col = c
	judge_t = 0.6


func _pick_fish() -> FishData:
	var total := 0.0
	for i in area.fish.size():
		total += _weight(i)
	var r := randf() * total
	for i in area.fish.size():
		r -= _weight(i)
		if _weight(i) > 0.0 and r < 0.0:
			return area.fish[i]
	return area.fish[_spot_indices()[0]]


## エリアごとの出現率。連続で釣るほど、売値の高い魚が出やすくなる
func _weight(i: int) -> float:
	var f: FishData = area.fish[i]
	if not _spot_indices().has(i):
		return 0.0
	var wgt := f.spawn_weight
	if i < area.weights.size():
		wgt = area.weights[i]
	if f.price >= 100:
		wgt *= 1.0 + 0.15 * chain
	return wgt


func _rarity(f: FishData) -> int:
	if f.spawn_weight >= 50.0:
		return 1
	if f.spawn_weight >= 25.0:
		return 2
	if f.spawn_weight >= 12.0:
		return 3
	if f.spawn_weight >= 6.0:
		return 4
	return 5


# ---------------- 描画 ----------------

func _hint() -> String:
	if state == State.IDLE:
		return message
	if state != State.PLAY:
		return ""
	if msg_t > 0.0:
		return message
	if fighting:
		return "ラインをなぞれ！ 切れたら終わり！ 赤い帯は指を離す"
	if break_until >= 0.0:
		return "CATCH!  次の小節からルアーアクション"
	if bite_queued or bite_t >= 0.0:
		return "来るぞ…！ 構えろ！"
	return "リズムでタップ！ ルアーを動かして誘え"


func _draw() -> void:
	var vp := get_viewport_rect().size
	var w := vp.x
	if state in [State.WORLD, State.SPOTS, State.JOURNAL, State.SETTLEMENT]:
		_draw_journey(vp)
		return
	if state == State.DEX:
		_draw_dex(vp)
		return
	if state == State.AREAS:
		_draw_areas(vp)
		return
	_draw_scenery(vp)
	draw_circle(Vector2(110, 290), 22, Color(0.95, 0.8, 0.65))
	draw_rect(Rect2(88, 312, 44, 30), Color(0.9, 0.3, 0.3))
	draw_line(ROD_BASE, ROD_TIP, Color(0.3, 0.2, 0.1), 5.0)
	var bp := bobber_pos
	if state == State.PLAY and not fighting:
		if lure_kick > 0.01:
			draw_arc(bp, 12.0 + (1.0 - lure_kick) * 40.0, 0, TAU, 32, Color(1, 1, 1, lure_kick * 0.8), 3.0)
		bp += Vector2(0, sin(time * 2.0) * 2.0 - lure_kick * 28.0)
	draw_line(ROD_TIP, bp, Color(1, 1, 1, 0.8), 2.0)
	if state != State.IDLE and state != State.TITLE:
		draw_circle(bp, 11, Color(0.95, 0.2, 0.2))
		draw_circle(bp + Vector2(0, -5), 6, Color.WHITE)
	if state == State.PLAY and fighting and current_fish:
		# 正確にラインを追うほど、ファイト中も魚の表示サイズが育つ
		var performance := slide_on / maxf(slide_seen, 0.1)
		var s := current_fish.size * (0.75 + 0.75 * clampf(performance, 0.0, 1.0))
		var fp := bp + Vector2(0, 40)
		draw_circle(fp, 20 * s, current_fish.color)
		draw_colored_polygon(PackedVector2Array([
			fp + Vector2(16, 0) * s, fp + Vector2(40, -14) * s, fp + Vector2(40, 14) * s]), current_fish.color)
	if flash_t > 0.0:
		_text("!", bp + Vector2(-10, -50), 64, Color(1, 0.9, 0.1), -1.0)

	if state == State.IDLE and charging:
		_bar(Rect2(w * 0.5 - 200, vp.y - 120, 400, 36), power, Color(1, 0.8, 0.2), "パワー")
	if state == State.PLAY:
		_draw_play(vp)

	if state == State.GAMEOVER:
		draw_rect(Rect2(0, 0, w, vp.y), Color(0, 0, 0, 0.6))
		_text("バラした…！", Vector2(w * 0.5, 440), 72, Color(1, 0.45, 0.4), w, true)
		_text("%s に糸を切られた" % over_fish, Vector2(w * 0.5, 510), 32, Color.WHITE, w, true)
		_text("釣果 %d 匹   所持金 %d 円" % [caught_total, money], Vector2(w * 0.5, 620), 42, Color.WHITE, w, true)
		_text("%s  ベスト %d 匹" % [area.area_name, _best()], Vector2(w * 0.5, 680), 34, Color(1, 0.9, 0.4), w, true)
		if go_t <= 0.0:
			_button(_btn_rect(0, vp, 760.0), "もう一度", menu_sel == 0)
			_button(_btn_rect(1, vp, 760.0), "MAPへ", menu_sel == 1)
	if state == State.TITLE:
		draw_rect(Rect2(0, 0, w, vp.y), Color(0, 0, 0, 0.45))
		_text("つりリズム", Vector2(w * 0.5, 440), 84, Color.WHITE, w, true)
		_text("リズムに乗って、釣り上げろ", Vector2(w * 0.5, 510), 30, Color(1, 1, 1, 0.85), w, true)
		_button(_btn_rect(0, vp, 700.0), "ストーリーモード", menu_sel == 0)
		_button(_btn_rect(1, vp, 700.0), "魚図鑑  %d / %d" % [_dex_found(), dex_list.size()], menu_sel == 1)
		_text("累計 %d 匹   図鑑 %d / %d" % [_total_caught(), _dex_found(), dex_list.size()], Vector2(w * 0.5, 1020), 30, Color(1, 0.9, 0.4), w, true)
	else:
		_text("所持金 %d 円   釣果 %d 匹" % [money, caught_total], Vector2(20, 50), 30, Color.BLACK, -1.0)
		if chain >= 2:
			_text("%d連続！" % chain, Vector2(20, 92), 34, Color(0.85, 0.3, 0.1), -1.0)
		_text(area.area_name + " / " + Journey.SPOTS[area.scenery][spot_index], Vector2(w * 0.5, 100), 26, Color(0, 0, 0, 0.7), w, true)
		_text(_hint(), Vector2(w * 0.5, 160), 30, Color.BLACK, w, true)
	if state == State.IDLE or state == State.CASTING or state == State.PLAY:
		var mr := Rect2(w - 190.0, 12.0, 170.0, 56.0)
		draw_rect(mr, Color(0, 0, 0, 0.35))
		draw_rect(mr, Color(1, 1, 1, 0.6), false, 2.0)
		_ctext("MAPへ", mr.position.x, mr.size.x, mr.position.y + 38.0, 26, Color.WHITE)


func _button(r: Rect2, label: String, selected: bool) -> void:
	draw_rect(r, Color(0.1, 0.3, 0.55, 0.92))
	if selected:
		draw_rect(r, Color(1, 0.9, 0.4), false, 5.0)
	else:
		draw_rect(r, Color(1, 1, 1, 0.7), false, 2.0)
	_ctext(label, r.position.x, r.size.x, r.position.y + r.size.y * 0.5 + 14.0, 38, Color.WHITE)


func _ctext(t: String, x: float, width: float, y: float, size: int, col: Color) -> void:
	draw_string(font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_CENTER, width, size, col)


func _draw_dex(vp: Vector2) -> void:
	var w := vp.x
	draw_rect(Rect2(0, 0, w, vp.y), Color(0.06, 0.14, 0.24))
	var top := 130.0
	var item_h := 190.0
	var max_scroll := maxf(0.0, dex_list.size() * item_h - (vp.y - top - 20.0))
	dex_scroll = clampf(dex_scroll, 0.0, max_scroll)
	for i in dex_list.size():
		var f: FishData = dex_list[i]
		var y := top + i * item_h - dex_scroll
		if y > vp.y or y < top - item_h:
			continue
		var entry: Dictionary = dex.get(f.fish_name, {})
		var count := int(entry.get("count", 0))
		var caught := count > 0
		draw_rect(Rect2(30, y, w - 60, 170), Color(1, 1, 1, 0.1))
		draw_rect(Rect2(30, y, w - 60, 170), Color(1, 1, 1, 0.25), false, 2.0)
		var c := Vector2(120, y + 85)
		var s := f.size * 0.9
		var col := f.color if caught else Color(0.02, 0.05, 0.1)
		draw_circle(c, 20.0 * s, col)
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(16, 0) * s, c + Vector2(40, -14) * s, c + Vector2(40, 14) * s]), col)
		var nm := f.fish_name if caught else "？？？"
		_text("No.%02d  %s" % [i + 1, nm], Vector2(250, y + 40), 30, Color.WHITE, -1.0)
		if caught:
			_text("売値%d円  釣獲%d匹  最高%s" % [f.price, count, String(entry.get("best", "-"))],
				Vector2(250, y + 72), 22, Color(1, 0.9, 0.5), -1.0)
		else:
			_text("まだ釣っていない", Vector2(250, y + 72), 22, Color(1, 1, 1, 0.5), -1.0)
		var rar := _rarity(f)
		for k in 5:
			var cp := Vector2(258 + k * 24, y + 94)
			if k < rar:
				draw_circle(cp, 7, Color(1, 0.8, 0.2))
			else:
				draw_arc(cp, 7, 0, TAU, 16, Color(1, 1, 1, 0.4), 2.0)
		_text("生息: " + _habitat(f), Vector2(250, y + 124), 20, Color(0.6, 0.85, 1.0, 0.9), -1.0)
		if caught:
			_text("最大サイズ %.2f" % float(entry.get("best_size", 0.0)), Vector2(250, y + 178), 19, Color.LIGHT_BLUE, -1.0)
			_text(f.description, Vector2(250, y + 154), 22, Color(1, 1, 1, 0.85), -1.0)
	draw_rect(Rect2(0, 0, w, top), Color(0.06, 0.14, 0.24))
	draw_line(Vector2(0, top), Vector2(w, top), Color(1, 1, 1, 0.3), 2.0)
	_ctext("魚図鑑", 0.0, w, 80.0, 52, Color.WHITE)
	_text("%d / %d" % [_dex_found(), dex_list.size()], Vector2(w - 150.0, 80.0), 32, Color(1, 0.9, 0.4), -1.0)
	var br := Rect2(20, 20, 170, 70)
	draw_rect(br, Color(0.1, 0.3, 0.55, 0.92))
	draw_rect(br, Color(1, 1, 1, 0.7), false, 2.0)
	_ctext("← 戻る", br.position.x, br.size.x, br.position.y + 46.0, 30, Color.WHITE)


func _draw_areas(vp: Vector2) -> void:
	var w := vp.x
	draw_rect(Rect2(0, 0, w, vp.y), Color(0.06, 0.14, 0.24))
	var top := 130.0
	var item_h := 190.0
	var max_scroll := maxf(0.0, areas.size() * item_h - (vp.y - top - 20.0))
	area_scroll = clampf(area_scroll, 0.0, max_scroll)
	for i in areas.size():
		var a: AreaData = areas[i]
		var y := top + i * item_h - area_scroll
		if y > vp.y or y < top - item_h:
			continue
		draw_rect(Rect2(30, y, w - 60, 170), Color(1, 1, 1, 0.1))
		# 左の見本（空と水の色）
		draw_rect(Rect2(30, y, 150, 100), a.sky_color)
		draw_rect(Rect2(30, y + 100, 150, 70), a.water_color)
		draw_rect(Rect2(30, y + 78, 60, 22), a.ground_color)
		draw_rect(Rect2(30, y, w - 60, 170), Color(1, 1, 1, 0.3), false, 2.0)
		_text(a.area_name, Vector2(200, y + 40), 34, Color.WHITE, -1.0)
		for k in 5:
			var cp := Vector2(w - 160 + k * 24, y + 30)
			if k < a.difficulty:
				draw_circle(cp, 8, Color(1, 0.5, 0.3))
			else:
				draw_arc(cp, 8, 0, TAU, 16, Color(1, 1, 1, 0.4), 2.0)
		_text(a.description, Vector2(200, y + 76), 22, Color(1, 1, 1, 0.85), -1.0)
		_text(a.feature, Vector2(200, y + 108), 22, Color(1, 0.9, 0.5), -1.0)
		var found := 0
		for f in a.fish:
			if int(dex.get(f.fish_name, {}).get("count", 0)) > 0:
				found += 1
		var best := int(best_by_area.get(a.area_name, 0))
		_text("BPM%d  図鑑%d/%d  ベスト%d匹" % [a.bpm, found, a.fish.size(), best],
			Vector2(200, y + 146), 20, Color(0.6, 0.85, 1.0, 0.9), -1.0)
	draw_rect(Rect2(0, 0, w, top), Color(0.06, 0.14, 0.24))
	draw_line(Vector2(0, top), Vector2(w, top), Color(1, 1, 1, 0.3), 2.0)
	_ctext("エリア選択", 0.0, w, 80.0, 48, Color.WHITE)
	var br := Rect2(20, 20, 170, 70)
	draw_rect(br, Color(0.1, 0.3, 0.55, 0.92))
	draw_rect(br, Color(1, 1, 1, 0.7), false, 2.0)
	_ctext("← 戻る", br.position.x, br.size.x, br.position.y + 46.0, 30, Color.WHITE)


# ---------------- 背景（エリアごとの景色） ----------------

func _ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var ang := TAU * i / 16.0
		pts.append(c + Vector2(cos(ang) * rx, sin(ang) * ry))
	draw_colored_polygon(pts, col)


func _poly(pts: Array, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array(pts), col)


func _draw_scenery(vp: Vector2) -> void:
	var w := vp.x
	draw_rect(Rect2(0, 0, w, WATER_Y), area.sky_color)
	draw_rect(Rect2(0, WATER_Y - 160.0, w, 160.0), area.sky_color.lightened(0.18))
	for i in 3:
		var cx := fmod(i * 260.0 + time * (8.0 + i * 3.0), w + 240.0) - 120.0
		var cy := 70.0 + i * 55.0
		_ellipse(Vector2(cx, cy), 70, 18, Color(1, 1, 1, 0.5))
		_ellipse(Vector2(cx + 30, cy - 10), 40, 16, Color(1, 1, 1, 0.5))
	_scenery_back(w)
	draw_rect(Rect2(0, WATER_Y, w, vp.y - WATER_Y), area.water_color)
	for i in 10:
		var yy := WATER_Y + 40.0 + i * 90.0
		var xx := fmod(i * 173.0 + time * (10.0 + i * 2.0), w + 200.0) - 100.0
		draw_line(Vector2(xx, yy), Vector2(xx + 60, yy), Color(1, 1, 1, 0.12), 3.0)
	_scenery_front(w)
	# プレイヤーが立つ足場
	draw_rect(Rect2(0, 340, 230, 60), area.ground_color)
	draw_rect(Rect2(0, 340, 230, 8), area.ground_color.lightened(0.25))


func _scenery_back(w: float) -> void:
	match area.scenery:
		"harbor":
			_poly([Vector2(540, 400), Vector2(556, 210), Vector2(584, 210), Vector2(600, 400)], Color(0.95, 0.95, 0.95))
			draw_rect(Rect2(552, 188, 36, 24), Color(0.85, 0.25, 0.25))
			_poly([Vector2(548, 188), Vector2(570, 168), Vector2(592, 188)], Color(0.3, 0.3, 0.35))
		"upstream":
			_poly([Vector2(0, 400), Vector2(160, 190), Vector2(330, 400)], Color(0.45, 0.58, 0.5))
			_poly([Vector2(220, 400), Vector2(420, 130), Vector2(640, 400)], Color(0.38, 0.52, 0.45))
			_poly([Vector2(480, 400), Vector2(640, 210), Vector2(740, 400)], Color(0.42, 0.55, 0.48))
			for i in 12:
				var x := i * 62.0 + 20.0
				_poly([Vector2(x, 400), Vector2(x + 16, 330 - (i % 3) * 14), Vector2(x + 32, 400)], Color(0.15, 0.35, 0.2))
		"midstream":
			draw_circle(Vector2(140, 470), 150, Color(0.5, 0.65, 0.4))
			draw_circle(Vector2(520, 490), 180, Color(0.45, 0.6, 0.38))
			draw_rect(Rect2(250, 330, 320, 12), Color(0.55, 0.55, 0.55))
			for i in 3:
				draw_rect(Rect2(280 + i * 120, 342, 10, 58), Color(0.5, 0.5, 0.5))
		"downstream":
			for i in 9:
				var h := 60.0 + float((i * 37) % 80)
				draw_rect(Rect2(i * 80.0 + 10.0, 400.0 - h, 56, h), Color(0.55, 0.6, 0.68))
			draw_rect(Rect2(0, 320, w, 12), Color(0.4, 0.4, 0.45))
			for i in 4:
				draw_rect(Rect2(60 + i * 190.0, 332, 12, 68), Color(0.4, 0.4, 0.45))
		"estuary":
			draw_circle(Vector2(520, 330), 70, Color(1, 0.7, 0.3, 0.45))
			draw_circle(Vector2(520, 330), 40, Color(1, 0.85, 0.5, 0.7))
			_ellipse(Vector2(520, 402), 200, 22, Color(0.85, 0.78, 0.58))
			for i in 3:
				var bx := fmod(i * 220.0 + time * 30.0, w + 100.0) - 50.0
				var by := 120.0 + i * 40.0 + sin(time * 2.0 + i) * 8.0
				draw_line(Vector2(bx - 12, by), Vector2(bx, by + 6), Color(0.2, 0.2, 0.2), 3.0)
				draw_line(Vector2(bx, by + 6), Vector2(bx + 12, by), Color(0.2, 0.2, 0.2), 3.0)
		"stream":
			_poly([Vector2(250, 400), Vector2(300, 60), Vector2(720, 40), Vector2(720, 400)], Color(0.28, 0.32, 0.3))
			draw_rect(Rect2(540, 60, 40, 340), Color(0.9, 0.95, 1, 0.8))
			for i in 4:
				draw_line(Vector2(548 + i * 9, 60), Vector2(548 + i * 9, 400), Color(1, 1, 1, 0.5), 2.0)
			for i in 6:
				var x := i * 45.0
				_poly([Vector2(x, 400), Vector2(x + 22, 290 - (i % 2) * 20), Vector2(x + 44, 400)], Color(0.12, 0.3, 0.2))
			draw_rect(Rect2(0, 300, w, 100), Color(1, 1, 1, 0.12))
		"swamp":
			draw_rect(Rect2(0, 230, w, 170), Color(0.8, 0.9, 0.7, 0.25))
			for x in [380.0, 540.0, 650.0]:
				draw_rect(Rect2(x, 200, 10, 200), Color(0.2, 0.15, 0.1))
				draw_line(Vector2(x + 5, 240), Vector2(x - 30, 210), Color(0.2, 0.15, 0.1), 4.0)
				draw_line(Vector2(x + 5, 270), Vector2(x + 40, 240), Color(0.2, 0.15, 0.1), 4.0)
		"pond":
			draw_rect(Rect2(560, 230, 16, 170), Color(0.3, 0.22, 0.15))
			draw_circle(Vector2(568, 220), 70, Color(0.35, 0.55, 0.3))
			for i in 9:
				var x := 500.0 + i * 16.0
				draw_line(Vector2(x, 220), Vector2(x + sin(time + i) * 4.0, 330), Color(0.3, 0.5, 0.25), 3.0)
			for i in 6:
				draw_line(Vector2(300 + i * 18.0, 400), Vector2(305 + i * 18.0, 350 - (i % 3) * 10), Color(0.5, 0.6, 0.3), 3.0)
		"lake":
			_poly([Vector2(0, 400), Vector2(200, 260), Vector2(420, 400)], Color(0.62, 0.72, 0.85))
			_poly([Vector2(300, 400), Vector2(520, 220), Vector2(740, 400)], Color(0.58, 0.68, 0.82))
		"paddy":
			draw_circle(Vector2(100, 520), 200, Color(0.6, 0.75, 0.5))
			draw_circle(Vector2(480, 540), 230, Color(0.55, 0.72, 0.48))
			draw_rect(Rect2(520, 320, 70, 50), Color(0.85, 0.75, 0.6))
			_poly([Vector2(510, 320), Vector2(555, 285), Vector2(600, 320)], Color(0.5, 0.3, 0.25))
			draw_rect(Rect2(400, 230, 6, 170), Color(0.3, 0.25, 0.2))
			draw_line(Vector2(380, 250), Vector2(430, 250), Color(0.3, 0.25, 0.2), 3.0)


func _scenery_front(w: float) -> void:
	match area.scenery:
		"harbor":
			for i in 3:
				var bx := 300.0 + i * 120.0
				_poly([Vector2(bx, 410), Vector2(bx + 50, 410), Vector2(bx + 40, 422), Vector2(bx + 8, 422)], Color(0.9, 0.9, 0.85))
				draw_line(Vector2(bx + 25, 410), Vector2(bx + 25, 385), Color(0.4, 0.4, 0.4), 3.0)
		"upstream", "stream":
			for i in 5:
				_ellipse(Vector2(300 + i * 100.0, 430 + (i % 2) * 20.0), 30, 14, Color(0.5, 0.5, 0.5))
			if area.scenery == "stream":
				for i in 8:
					var fx := fmod(i * 97.0 + time * 40.0, w)
					draw_line(Vector2(fx, 470 + i * 70.0), Vector2(fx + 40, 470 + i * 70.0), Color(1, 1, 1, 0.3), 3.0)
		"downstream":
			for i in 8:
				draw_line(Vector2(240 + i * 8.0, 400), Vector2(240 + i * 8.0 + sin(time + i) * 3.0, 350 - (i % 3) * 10.0), Color(0.5, 0.6, 0.3), 3.0)
		"estuary":
			draw_circle(Vector2(200, 440), 8, Color(0.9, 0.2, 0.2))
		"swamp":
			for i in 9:
				var c := Vector2(80.0 + float((i * 83) % 600), 440.0 + float((i * 137) % 700))
				_ellipse(c, 28, 10, Color(0.25, 0.45, 0.2))
				if i % 3 == 0:
					draw_circle(c + Vector2(0, -6), 5, Color(0.95, 0.8, 0.9))
		"pond":
			for i in 7:
				var c := Vector2(90.0 + float((i * 97) % 560), 450.0 + float((i * 151) % 600))
				_ellipse(c, 30, 11, Color(0.3, 0.5, 0.3))
				if i % 2 == 0:
					draw_circle(c + Vector2(0, -7), 6, Color(1, 0.7, 0.8))
		"lake":
			_poly([Vector2(470, 418), Vector2(540, 418), Vector2(525, 432), Vector2(485, 432)], Color(0.95, 0.95, 0.95))
			_poly([Vector2(505, 418), Vector2(505, 360), Vector2(535, 418)], Color(1, 1, 1))
		"paddy":
			for r in 12:
				var y := 430.0 + r * 65.0
				for c in 20:
					var x := c * 36.0 + (r % 2) * 18.0
					draw_line(Vector2(x, y), Vector2(x + sin(time * 2.0 + c) * 2.0, y - 18.0), Color(0.4, 0.7, 0.25), 3.0)


func _t_to_y(t: float, judge_y: float) -> float:
	return judge_y - (t - song_t) / lead * FALL


func _draw_play(vp: Vector2) -> void:
	var w := vp.x
	var lane_w := w - SIDE_MARGIN * 2.0
	var judge_y := vp.y - 300.0
	var top_y := judge_y - FALL
	var bottom_y := judge_y + 80.0
	# プレイフィールド。ファイト中はテンションに応じて赤く染まる
	var field := Color(0, 0, 0, 0.28)
	if fighting:
		field = field.lerp(Color(0.7, 0.05, 0.05, 0.45), clampf(tension, 0.0, 1.0))
	draw_rect(Rect2(SIDE_MARGIN, top_y, lane_w, FALL + 80.0), field)
	draw_rect(Rect2(SIDE_MARGIN, top_y, lane_w, FALL + 80.0), Color(1, 1, 1, 0.25), false, 2.0)
	if not fighting:
		draw_rect(Rect2(w * 0.5 - 110, top_y, 220, FALL + 80.0), Color(1, 1, 1, 0.07))
	# 赤い帯 = 指を離すゾーン
	for r in releases:
		var ya := maxf(_t_to_y(float(r["t1"]), judge_y), top_y)
		var yb := minf(_t_to_y(float(r["t0"]), judge_y), bottom_y)
		if yb <= ya:
			continue
		draw_rect(Rect2(SIDE_MARGIN, ya, lane_w, yb - ya), Color(1, 0.2, 0.2, 0.4))
		if yb - ya > 40.0:
			_text("離す！", Vector2(w * 0.5, (ya + yb) * 0.5 + 14.0), 40, Color(1, 1, 1, 0.9), w, true)
	# スライドライン
	var tol_px := _tol() * lane_w
	for s in slides:
		var t0 := float(s["t0"])
		var t1 := float(s["t1"])
		if t1 < song_t - 0.3 or t0 > song_t + lead:
			continue
		var pts := PackedVector2Array()
		var t := maxf(t0, song_t - 0.3)
		var t_end := minf(t1, song_t + lead)
		while t < t_end:
			pts.append(Vector2(SIDE_MARGIN + _slide_x(s["pts"], t) * lane_w, _t_to_y(t, judge_y)))
			t += 0.04
		pts.append(Vector2(SIDE_MARGIN + _slide_x(s["pts"], t_end) * lane_w, _t_to_y(t_end, judge_y)))
		if pts.size() >= 2:
			draw_polyline(pts, Color(0.4, 0.8, 1.0, 0.4), tol_px * 2.0)
			draw_polyline(pts, Color(1, 1, 1, 0.9), 6.0)
	# ルアーアクションのタップノーツ
	for n in taps:
		var dt := float(n["t"]) - song_t
		if dt > lead or dt < -0.4 or n["s"] == 1 or n["s"] == 2:
			continue
		var y := judge_y - dt / lead * FALL
		var col := Color(1, 0.85, 0.3) if n["s"] == 0 else Color(0.5, 0.5, 0.5, 0.6)
		draw_circle(Vector2(w * 0.5, y), 36, col)
		draw_arc(Vector2(w * 0.5, y), 36, 0, TAU, 32, Color.WHITE, 3.0)
	# HIT!! マーカー（ここから譜面がスライドに変わる）
	if bite_t >= 0.0:
		var bdt := bite_t - song_t
		if bdt <= lead and bdt >= -0.3:
			var by := judge_y - bdt / lead * FALL
			draw_rect(Rect2(SIDE_MARGIN, by - 6.0, lane_w, 12.0), Color(1, 0.85, 0.2))
			_text("HIT!!", Vector2(w * 0.5, by - 16.0), 44, Color(1, 0.9, 0.3), w, true)
	# 判定ラインと指
	draw_line(Vector2(SIDE_MARGIN, judge_y), Vector2(w - SIDE_MARGIN, judge_y), Color(1, 1, 1, 0.9), 4.0)
	if not fighting:
		draw_arc(Vector2(w * 0.5, judge_y), 40, 0, TAU, 32, Color(1, 0.85, 0.3), 4.0)
	if cur_target >= 0.0 and fighting:
		draw_circle(Vector2(SIDE_MARGIN + cur_target * lane_w, judge_y), 14, Color.WHITE)
	if fighting:
		var fx := SIDE_MARGIN + finger_x * lane_w
		if held:
			var col := Color(0.3, 0.95, 0.4, 0.85) if on_path else (Color(1, 0.3, 0.3, 0.85) if strained else Color(1, 1, 1, 0.6))
			draw_circle(Vector2(fx, judge_y), 30, col)
		else:
			draw_arc(Vector2(fx, judge_y), 30, 0, TAU, 32, Color(1, 1, 1, 0.5), 3.0)
	# ゲージ
	if fighting:
		_bar(Rect2(w * 0.5 - 200, vp.y - 200, 400, 36), tension, Color(1, 0.3, 0.2), "テンション")
		_bar(Rect2(w * 0.5 - 200, vp.y - 140, 400, 36), progress, Color(0.3, 0.9, 0.4), "引き寄せ")
		if cur_release:
			_text("指を離せ！", Vector2(w * 0.5, judge_y - 150), 56, Color(1, 0.9, 0.3), w, true)
	else:
		_bar(Rect2(w * 0.5 - 200, vp.y - 140, 400, 36), appeal, Color(1, 0.7, 0.2), "アピール")
	if judge_t > 0.0:
		_text(judge_text, Vector2(w * 0.5, judge_y - 90), 48, judge_col, w, true)


func _bar(r: Rect2, value: float, col: Color, label: String) -> void:
	draw_rect(r, Color(0, 0, 0, 0.5))
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(value, 0.0, 1.0), r.size.y)), col)
	draw_rect(r, Color.WHITE, false, 3.0)
	_text(label, r.position + Vector2(8, 28), 22, Color.WHITE, -1.0)


func _text(t: String, pos: Vector2, size: int, col: Color, width: float, center := false) -> void:
	if center:
		draw_string(font, Vector2(0, pos.y), t, HORIZONTAL_ALIGNMENT_CENTER, width, size, col)
	else:
		draw_string(font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


# ストーリーと地図。既存図鑑の釣果は依頼に遡及せず、その章の釣果を記録する。
func _spot_indices() -> Array:
	var n := area.fish.size()
	if spot_index == 0:
		return [0, 1] if n > 1 else [0]
	if spot_index == 1:
		return [1, 2] if n > 2 else [n - 1]
	var result: Array = []
	for i in range(2, n):
		result.append(i)
	return result if not result.is_empty() else [n - 1]

func _quest_area() -> AreaData:
	return areas[mini(chapter, areas.size() - 1)]

func _record_story_catch() -> String:
	var key := "%s:%d:%s" % [area.scenery, spot_index, current_fish.fish_name]
	story_catches[key] = int(story_catches.get(key, 0)) + 1
	if chapter >= areas.size() or area != _quest_area():
		return ""
	var target_spot := chapter % 3
	var indices := _spot_indices()
	if spot_index != target_spot or current_fish != area.fish[indices[0]]:
		return ""
	quest_count += 1
	if quest_count < 2:
		return "  依頼 1/2！"
	chapter += 1
	quest_count = 0
	return "  依頼達成！ 次のエリア解放" if chapter < areas.size() else "  全章クリア！"

func _return_map() -> void:
	_update_best()
	_save()
	_reset_chart()
	charging = false
	held = false
	jp = false
	jr = false
	_music_set("title")
	state = State.SPOTS

func _map_point(i: int, vp: Vector2) -> Vector2:
	return Vector2(vp.x * (0.27 if i % 2 == 0 else 0.73), 300.0 + i * 72.0)

func _spot_point(i: int, vp: Vector2) -> Vector2:
	return Vector2(vp.x * [0.25, 0.72, 0.43][i], [400.0, 550.0, 720.0][i])

func _journey_press(pos: Vector2) -> void:
	var vp := get_viewport_rect().size
	if Rect2(20, 20, 160, 65).has_point(pos):
		_back_action()
		return
	if state == State.WORLD:
		for j in SETTLEMENTS.size():
			var sr := Rect2(30.0 + j * (vp.x - 60.0) / 3.0, 1020, (vp.x - 60.0) / 3.0 - 8.0, 84)
			if sr.has_point(pos):
				if chapter >= int(SETTLEMENTS[j]["chapter"]):
					settlement_index = j
					state = State.SETTLEMENT
				return
		if Rect2(vp.x - 190, 20, 170, 65).has_point(pos):
			state = State.JOURNAL
			return
		for i in areas.size():
			if pos.distance_to(_map_point(i, vp)) < 52 and i <= chapter:
				area = areas[i]
				_apply_area()
				spot_index = 0
				state = State.SPOTS
				return
	elif state == State.SETTLEMENT:
		if Rect2(50, 990, vp.x - 100, 100).has_point(pos):
			state = State.WORLD
	elif state == State.SPOTS:
		for i in 3:
			if pos.distance_to(_spot_point(i, vp)) < 65:
				spot_index = i
				return
		if Rect2(60, 1110, vp.x - 120, 90).has_point(pos):
			_start_game()

func _draw_journey(vp: Vector2) -> void:
	var w := vp.x
	draw_rect(Rect2(Vector2.ZERO, vp), Color("233d34"))
	# RPG風のフィールド: 草原、山、湖、街道。すべてコード描画。
	for yy in range(220, 990, 45):
		for xx in range(12, int(w), 48):
			var seedv := (xx * 17 + yy * 31) % 13
			var c := Color("406f45") if seedv < 7 else Color("56814c")
			draw_rect(Rect2(xx, yy, 46, 43), c)
			if seedv == 1:
				_poly([Vector2(xx + 8, yy + 33), Vector2(xx + 24, yy + 5), Vector2(xx + 39, yy + 33)], Color("798a76"))
			elif seedv == 2:
				draw_circle(Vector2(xx + 22, yy + 22), 12, Color("28543d"))
	# 水路と道がエリアをつなぐ
	var stream_pts := PackedVector2Array([Vector2(w * 0.89, 240), Vector2(w * 0.67, 370), Vector2(w * 0.85, 520), Vector2(w * 0.62, 680), Vector2(w * 0.83, 930)])
	draw_polyline(stream_pts, Color("448caf"), 48, true)
	_button(Rect2(20, 20, 160, 65), "← 戻る", false)
	if state == State.WORLD:
		_button(Rect2(w - 190, 20, 170, 65), "冒険手帳", false)
		_ctext("水のうたをたどる旅", 0, w, 150, 38, Color.WHITE)
		_ctext("釣り場を選んで、各地の依頼を達成しよう", 0, w, 205, 24, Color.LIGHT_BLUE)
		for i in range(areas.size() - 1):
			draw_line(_map_point(i, vp), _map_point(i + 1, vp), Color("b8a273"), 19)
			draw_line(_map_point(i, vp), _map_point(i + 1, vp), Color("e1ce9b"), 9)
		for i in areas.size():
			var pt := _map_point(i, vp)
			var unlocked := i <= chapter
			draw_circle(pt, 37, Color("e0b75b") if unlocked else Color("34404d"))
			draw_arc(pt, 40, 0, TAU, 32, Color("fff1c9") if unlocked else Color("65747a"), 3)
			_ctext(str(i + 1), pt.x - 30, 60, pt.y + 10, 28, Color.BLACK)
			_ctext(areas[i].area_name if unlocked else "未踏の地", pt.x - 110, 220, pt.y + 64, 25, Color.WHITE)
		for j in SETTLEMENTS.size():
			var v: Dictionary = SETTLEMENTS[j]
			var opened := chapter >= int(v["chapter"])
			var sr := Rect2(30.0 + j * (w - 60.0) / 3.0, 1020, (w - 60.0) / 3.0 - 8.0, 84)
			draw_rect(sr, Color("936e43") if opened else Color("404b4c"))
			_poly([Vector2(sr.position.x + 12, sr.position.y + 18), Vector2(sr.position.x + sr.size.x * 0.5, sr.position.y - 15), Vector2(sr.end.x - 12, sr.position.y + 18)], Color("bd604c") if opened else Color("44494a"))
			_ctext(str(v["name"]) if opened else "未解放", sr.position.x, sr.size.x, sr.position.y + 57, 21, Color.WHITE)
		_ctext("金色の地点で釣り場 / 建物で村・町・市へ", 0, w, 1140, 24, Color.WHITE)
		_ctext("冒険手帳で現在の依頼を確認", 0, w, 1180, 24, Color.WHITE)
	elif state == State.SETTLEMENT:
		var village: Dictionary = SETTLEMENTS[settlement_index]
		_ctext(str(village["kind"]) + "  " + str(village["name"]), 0, w, 175, 45, Color.WHITE)
		for house in 5:
			var hx := 65.0 + house * (w - 125.0) / 5.0
			var hy := 440.0 + float(house % 2) * 105.0
			draw_rect(Rect2(hx, hy, 95, 90), Color("d8bc8b"))
			_poly([Vector2(hx - 10, hy), Vector2(hx + 47, hy - 60), Vector2(hx + 105, hy)], Color("a24f43"))
			draw_rect(Rect2(hx + 32, hy + 48, 28, 42), Color("6f5039"))
		_ctext(str(village["intro"]), 20, w - 40, 730, 24, Color.WHITE)
		_ctext(str(village["tip"]), 20, w - 40, 810, 25, Color("f5df9c"))
		_ctext("拠点を訪問中 / 次の目的地は冒険手帳を確認", 20, w - 40, 905, 21, Color.LIGHT_BLUE)
		_button(Rect2(50, 990, w - 100, 100), "フィールドへ戻る", true)
	elif state == State.SPOTS:
		_ctext(area.area_name + " / 釣り座MAP", 0, w, 150, 38, Color.WHITE)
		_ctext("釣り座を選択 → キャスティング開始", 0, w, 210, 25, Color.LIGHT_BLUE)
		draw_rect(Rect2(35, 270, w - 70, 560), area.ground_color.darkened(0.3))
		var river := PackedVector2Array([Vector2(w * 0.5, 285), Vector2(w * 0.35, 410), Vector2(w * 0.62, 570), Vector2(w * 0.48, 810)])
		draw_polyline(river, area.water_color.lightened(0.1), 125, true)
		for i in 3:
			var pt := _spot_point(i, vp)
			draw_circle(pt, 36, Color("edc968") if spot_index == i else Color("244356"))
			draw_arc(pt, 42, 0, TAU, 40, Color.WHITE, 2)
			_ctext(str(i + 1), pt.x - 30, 60, pt.y + 12, 30, Color.WHITE)
			_ctext(Journey.SPOTS[area.scenery][i], 40, w - 80, pt.y + 65, 26, Color.WHITE)
		_ctext("選択中：" + Journey.SPOTS[area.scenery][spot_index], 0, w, 890, 30, Color("edc968"))
		var names := PackedStringArray()
		for index in _spot_indices():
			names.append(area.fish[index].fish_name)
		_ctext("釣れる魚", 0, w, 945, 24, Color.LIGHT_BLUE)
		_ctext(" / ".join(names), 20, w - 40, 990, 26, Color.WHITE)
		_ctext("長押しして離すとキャスト。魚はこの釣り座から抽選", 0, w, 1050, 21, Color.LIGHT_BLUE)
		_button(Rect2(60, 1110, w - 120, 90), "ここで釣りを始める", true)
	else:
		_ctext("冒険手帳", 0, w, 155, 44, Color.WHITE)
		_ctext("水辺の音が消えかけた村。", 0, w, 260, 28, Color.WHITE)
		_ctext("師匠とともに、魚たちのリズムを集める旅へ。", 0, w, 310, 26, Color.WHITE)
		if chapter >= areas.size():
			_ctext("終章：水辺にうたが戻った", 0, w, 460, 36, Color("edc968"))
			_ctext("全エリア解放！ 図鑑を完成させる旅は続く。", 0, w, 540, 26, Color.WHITE)
			return
		var target := _quest_area()
		var target_spot := chapter % 3
		var fish_index: int = target_spot
		_ctext("第%d章：%sの調べ" % [chapter + 1, target.area_name], 0, w, 430, 34, Color("edc968"))
		_ctext(Journey.LINES[chapter], 20, w - 40, 510, 26, Color.WHITE)
		_ctext("場所：" + target.area_name, 0, w, 620, 30, Color.LIGHT_BLUE)
		_ctext("釣り座：" + Journey.SPOTS[target.scenery][target_spot], 0, w, 680, 30, Color.WHITE)
		_ctext("依頼：%sを2匹釣る（%d / 2）" % [target.fish[fish_index].fish_name, quest_count], 0, w, 760, 30, Color.WHITE)
		_ctext("達成すると、次のエリアが解放されます。", 0, w, 880, 25, Color.LIGHT_BLUE)
		_ctext("依頼と図鑑は自動保存されます。", 0, w, 940, 25, Color.LIGHT_BLUE)
