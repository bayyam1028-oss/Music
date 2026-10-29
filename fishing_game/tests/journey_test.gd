extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.chapter = 0
	game.quest_count = 0
	game.story_catches.clear()
	game._title_action(0)
	assert(game.state == game.State.WORLD)
	# 未解放エリアをクリックしても移動しない。
	game._journey_press(game._map_point(1, game.get_viewport_rect().size))
	assert(game.state == game.State.WORLD)
	for chapter in game.areas.size():
		game.area = game.areas[chapter]
		game._apply_area()
		for spot in 3:
			game.spot_index = spot
			var allowed: Array = game._spot_indices()
			assert(not allowed.is_empty())
			for trial in 300:
				assert(game.area.fish.find(game._pick_fish()) in allowed)
		# 別の釣り座で釣っても依頼は進まない。
		game.spot_index = (chapter + 1) % 3
		game.current_fish = game.area.fish[game._spot_indices()[0]]
		game._record_story_catch()
		assert(game.quest_count == 0)
		game.spot_index = chapter % 3
		game.current_fish = game.area.fish[game._spot_indices()[0]]
		game._record_story_catch()
		assert(game.quest_count == 1)
		game._save()
		game.quest_count = 0
		game._load_save()
		assert(game.quest_count == 1)
		game._record_story_catch()
		assert(game.chapter == chapter + 1)
		assert(game.quest_count == 0)
	game._save()
	game.chapter = 0
	game._load_save()
	assert(game.chapter == game.areas.size())
	# 各画面の描画と開始・MAP帰還。
	for screen in [game.State.WORLD, game.State.SPOTS, game.State.JOURNAL]:
		game.state = screen
		game.queue_redraw()
		await process_frame
	game._start_game()
	assert(game.state == game.State.IDLE)
	game.jp = true
	game._idle(0.3)
	game.jp = false
	game.jr = true
	game._idle(0.1)
	assert(game.state == game.State.CASTING)
	game.jr = false
	game._casting(0.7)
	assert(game.state == game.State.PLAY)
	game._return_map()
	assert(game.state == game.State.SPOTS)
	assert(not game.held)
	print("PASS: 30 spot pools / 9000 draws, 10 quests, save/load, cast and map return")
	game.queue_free()
	await process_frame
	quit()
