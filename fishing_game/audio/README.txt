audio/ の曲について
====================
ここにある .ogg は、tools/make_music.py が「コードだけで合成」したオリジナル曲です。
サンプル音源・既存曲は一切使っていません。作者は権利を放棄（CC0）しており、
商用利用・改変・再配布・クレジット表記なし、すべて自由に使えます。

構成（1曲 = 2ファイル）
  <ID>_<1|2>_a.ogg : 土台（パッド・ベース・キック）… いつも鳴る
  <ID>_<1|2>_b.ogg : 盛り上げ（メロディ・ハイハット・スネア・アルペジオ）… ファイト中にフェードイン

ID: title / harbor / upstream / midstream / downstream / estuary / stream / swamp / pond / lake / paddy
エリアごとに2曲、プレイ開始のたびにランダムで選ばれます。

自作・他の曲に差し替えるとき
  - 同じファイル名で上書きする
  - テンポはエリアの bpm（data/areas/*.tres）と同じにする
  - 長さはぴったり整数小節（8小節ループを推奨）にする
  - a と b は同じ長さにそろえる
曲を作り直すときは python3 tools/make_music.py（numpy / scipy / ffmpeg が必要）。
