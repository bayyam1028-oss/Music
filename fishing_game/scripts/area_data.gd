class_name AreaData
extends Resource
## 釣り場1か所ぶんのデータ。data/areas/*.tres をインスペクターで編集できます。
## 魚の顔ぶれ・テンポ・ラインの幅・見た目など、エリアごとの「個性」をここで決めます。

@export var area_name: String = "波止場"
@export var description: String = ""   ## 一言説明（15文字くらいまで）
@export var feature: String = ""       ## 特徴（15文字くらいまで）
## 背景の種類: harbor / upstream / midstream / downstream / estuary / stream / swamp / pond / lake / paddy
@export var scenery: String = "harbor"
@export var sky_color: Color = Color(0.62, 0.82, 0.95)
@export var water_color: Color = Color(0.12, 0.38, 0.62)
@export var ground_color: Color = Color(0.5, 0.5, 0.5)
@export_range(1, 5) var difficulty: int = 2
## 流す曲のID（audio/<ID>_1_a.ogg など）。空なら scenery と同じIDを使う
@export var music: String = ""

@export_group("音ゲーの個性")
@export_range(60, 200) var bpm: int = 120
## 譜面が見えている時間（秒）。短いほど先が見えにくい
@export_range(0.8, 2.0, 0.1) var lead: float = 1.4
## スライドラインの幅の倍率。小さいほどシビア
@export_range(0.5, 1.5, 0.05) var tol_scale: float = 1.0
## 魚の引きの強さの倍率（テンションの上がりやすさ）
@export_range(0.5, 2.0, 0.05) var pull_scale: float = 1.0
## スライドラインの揺れ方の倍率
@export_range(0.5, 2.0, 0.05) var wobble_scale: float = 1.0
## 「指を離す」帯の長さの倍率
@export_range(0.5, 2.0, 0.05) var release_scale: float = 1.0
## アタリの来やすさの倍率
@export_range(0.3, 2.0, 0.05) var bite_rate: float = 1.0
## 潮・風でラインの幅が伸び縮みする強さ（0で無し）
@export_range(0.0, 0.6, 0.05) var tide: float = 0.0
## ルアーアクションのタップ密度: 0=のんびり 1=ふつう 2=せわしない
@export_range(0, 2) var lure_style: int = 1

@export_group("魚")
@export var fish: Array[FishData] = []
## fish と同じ順の出現率。足りない分は魚データの spawn_weight を使う
@export var weights: PackedFloat32Array = PackedFloat32Array()
