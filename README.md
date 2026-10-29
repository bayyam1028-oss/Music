# つりリズム — ストーリーモード

Godot製の釣り×リズムゲーム。開発元データは2026-10-21版 `fishing_rhythm_story.zip`（`fishing_game/`）です。

## 現状（2026-10-29）

**以前のREADMEで案内していた `fishing_rhythm_famous_music.zip` はこのリポジトリに存在せず、リンクが切れていました。** 誤ったダウンロード案内を削除しました。

ユーザーから受領した `fishing_rhythm_story.zip` の確認結果：
- `fishing_game/project.godot`、`main.tscn`、GDScript、音声、魚・エリアリソース、テストを含む
- 10章、10エリア、各3釣り座（計30釣り座）のストーリーモード試作
- キャスト／釣り音ゲー／依頼／エリア解放／図鑑／セーブ機能
- 音源は同梱の `tools/make_music.py` で合成されたオリジナル曲
- **以前の「有名曲9主題・165アレンジ」は今回受領したZIPでは確認できず、完成済みとは扱いません。**

### 起動

プロジェクトZIPを取得して展開後、Godot 4.6以降で `fishing_game/project.godot` を開き、F5で実行します。Godot 4.6.3で動作確認した旨が同梱READMEに記載されています（今回の環境で再テスト済みという意味ではありません）。

### テスト

```sh
cd fishing_game
godot --headless --path . --script res://tests/journey_test.gd
```

テストはセーブを更新するため専用ユーザーデータ環境で実行してください。

### GitHubへの移行状況

このリポジトリには現在、ゲーム本体ZIPやソースが**まだ登録されていません**。このREADMEは受領ZIPの構成を記録するもので、ダウンロード可能な完成版を装いません。GitHubへのバイナリ本体の移行と実機検証は未完了です。
