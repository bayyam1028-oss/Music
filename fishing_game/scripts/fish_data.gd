class_name FishData
extends Resource
## 魚1種類ぶんのデータ。data/*.tres をインスペクターで編集できます。
## 魚ごとに「ファイト部分」の長さ・スライドの動き・離す長さが決まります。

@export var fish_name: String = "さかな"
## 図鑑に表示される説明文（20文字くらいまで）
@export var description: String = ""
@export var price: int = 10
## 釣り上げに必要な量の目安（拍数）。長いほどたくさんなぞる必要がある
@export_range(8, 64) var beats: int = 16
## スライドラインの動きの激しさ（0.1〜1.0）。大きいほどラインが大きく振れる
@export_range(0.1, 1.0, 0.05) var note_density: float = 0.5
## 「指を離す」赤い帯の長さ（拍）
@export_range(0.5, 3.0, 0.5) var release_beats: float = 1.0
## テンションの上がりやすさ
@export_range(0.1, 3.0, 0.1) var pull_strength: float = 1.0
## 出現しやすさ。大きいほどよく釣れる
@export var spawn_weight: float = 10.0
@export var color: Color = Color.WHITE
@export_range(0.5, 3.0, 0.1) var size: float = 1.0
