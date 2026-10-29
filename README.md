# つりリズム — ストーリーモード

ユーザー提供の `fishing_rhythm_story.zip` を元に、プロジェクト本体・魚36種・エリア10か所・音声44ファイル・テスト・音源生成スクリプトを登録しました。

## ダウンロードと起動

[プロジェクトZIPをダウンロード](https://github.com/bayyam1028-oss/Music/archive/refs/heads/main.zip)

解凍後、Godot 4.6以降で `Music-main/fishing_game/project.godot` を開き、F5で実行してください。
元ZIPのREADMEにはGodot 4.6.3で確認した旨が記載されています。今回の登録後の検証結果は[GitHub Actions](https://github.com/bayyam1028-oss/Music/actions)で確認できます。

## 内容

- 全10章、10エリア、各3釣り座（計30か所）のストーリーモード試作
- キャスト、釣り音ゲー、依頼、エリア解放、図鑑、進行状況の保存
- 操作方法・実装範囲・検証手順：`fishing_game/README_ストーリーモード.md`
- 音源の説明と利用条件：`fishing_game/audio/README.txt`
- 音源生成：`fishing_game/tools/make_music.py`
- 検証スクリプト：`fishing_game/tests/journey_test.gd`

音源READMEは同梱のオリジナル合成音源をCC0と記載しています。ゲームコード全体のライセンスを示すものではありません。

以前案内されていた「有名曲9主題・165アレンジ」版は今回の提供ZIPには含まれていません。壊れていた `fishing_rhythm_famous_music.zip` のリンクは使用しません。

## 検証

```sh
cd fishing_game
godot --headless --path . --editor --quit
godot --headless --path . --script res://tests/journey_test.gd
```

テストはセーブを書き込むため、専用のユーザーデータ環境で実行してください。GitHub Actionsはインポート・テスト成功後に配布ZIPのArtifactを生成します。
