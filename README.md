# shoestring_data_sync
Automates re-syncing a Symbol (XYM) node by applying the latest blockchain snapshot. This script handles the entire process: safe shutdown, harvesters.dat backup, Docker cleanup, data replacement, and restart. It also auto-creates detailed, timestamped logs for easy troubleshooting. Ideal for symbol-shoestring users.

---

# Symbol-shoestring ノード データ自動同期スクリプト

## 概要 (Overview)

このスクリプトは、`symbol-shoestring`で構築したSymbol (XYM) ノードのブロックチェーンデータを、最新のスナップショットからダウンロードし、置き換えるためのものです。手動での煩雑な作業をなくし、迅速なデータ同期を実現します。

実行時の全プロセスは、タイムスタンプ付きのログファイルとして自動的に保存されます。

---

## 機能 (Features)

-   **全自動処理**: ノードの停止からデータ置換、再起動、ヘルスチェックまでを自動で実行します。
-   **高速同期**: 最新のブロックチェーン・スナップショットをダウンロードするため、ゼロから同期するよりも大幅に時間を短縮できます。
-   **委任情報の保全**: `harvesters.dat`（委任ハーベスティング設定）を自動でバックアップし、データ置換後に復元します。
-   **Dockerクリーンアップ**: 不要になったDockerコンテナやボリュームを自動的に削除し、ディスク容量を節約します。
-   **自動ログ生成**: 実行日時をファイル名に含む詳細なログ (`node_data_sync_YYYYMMDD_HHMMSS.log`) を自動で作成し、問題発生時の原因究明をサポートします。

---

## 前提条件 (Prerequisites)

-   Symbol-shoestring インストールディレクトリにて実行すること。
-   インストールディレクトリには、 `docker-compose.yaml`  `shoestring.ini` が存在すること。  
    -   直下にファイルが無い場合は、存在する場所を指定してください。
-   `git`  `docker`  `docker-compose`  `wget` がインストール済み。
-   **`pigz`** (マルチスレッドで動作するgzip解凍並列処理化用)
    -   Debian/Ubuntu系: `sudo apt-get install pigz`
-   **`pv`** (プログレスバー表示用)
    -   Debian/Ubuntu系: `sudo apt-get install pv`

---

## 使い方 (Usage)

### 初回セットアップ手順

1.  **ノードのインストールディレクトリに移動**
    ターミナルを開き、`cd`コマンドであなたの`symbol-shoestring`ノードがインストールされているディレクトリに移動します。
    （`docker-compose.yaml`や`shoestring.ini`がある場所です ）
    ```sh
    # 例
    cd /home/user/my-symbol-node
    ```

2.  **リポジトリをクローン**
    現在のディレクトリ（ノードのルート）に、このスクリプトのリポジトリをダウンロードします。
    ```sh
    git clone https://github.com/MassFactory/shoestring_data_sync.git
    ```
    これにより、`shoestring_data_sync`という名前の新しいフォルダが作成されます。

3.  **スクリプトのディレクトリに移動**
    作成されたフォルダの中に移動します。
    ```sh
    cd shoestring_data_sync
    ```

4.  **実行権限を付与**
    スクリプトに実行権限を与えます。この作業は初回のみ必要です。
    ```sh
    chmod +x shoestring_data_sync.sh
    ```

### 実行方法

セットアップ完了後、データを同期したい時はいつでも以下のコマンドを実行します。

1.  スクリプトのあるディレクトリ (`.../shoestring_data_sync`) にいることを確認してください。
2.  以下のコマンドでスクリプトを実行します。
    ```sh
    ./shoestring_data_sync.sh
    ```
    実行後、確認メッセージが表示されますので、`y`を入力して処理を続行してください。

---

## スクリプトのアップデート方法

スクリプトに新しいバージョンが公開された場合は、以下の手順でアップデートしてください。フォルダを削除する必要はありません。

1.  **スクリプトのディレクトリに移動**
    ```sh
    cd /path/to/your/node/shoestring_data_sync
    ```

2.  **変更内容を取得**
    `git pull`コマンドを実行すると、スクリプトが最新の状態に更新されます。ダウンロード途中のデータは保持されます。
    ```sh
    git pull
    ```

---

## 注意事項 (Important Notes)

-   **データの上書き**: このスクリプトを実行すると、ノードのブロックチェーンデータは**完全に削除され**、ダウンロードした新しいデータに置き換えられます。
-   **自己責任での利用**: 本スクリプトの使用によって生じたいかなる損害についても、作成者は責任を負いません。内容を理解した上で、自己責任でご利用ください。
-   **データ提供元**: ブロックチェーン・スナップショットは[オープニングライン様](https://symbol-archive.opening-line.jp/)のアーカイブを利用させていただいております。オープニングライン様、マジ感謝です。

