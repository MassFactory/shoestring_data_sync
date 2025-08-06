# shoestring_data_sync
Automates re-syncing a Symbol (XYM) node by applying the latest blockchain snapshot. This script handles the entire process: safe shutdown, harvesters.dat backup, Docker cleanup, data replacement, and restart. It also auto-creates detailed, timestamped logs for easy troubleshooting. Ideal for symbol-shoestring users.

# Symbol-shoestring ノード データ自動同期スクリプト

## 概要 (Overview)

このスクリプトは、`symbol-shoestring`で構築したSymbol (XYM) ノードのブロックチェーンデータを、最新のスナップショットから自動でダウンロードし、同期チェーンデータをノードに置き換えるためのものです。手動での煩雑な作業をなくし、迅速なデータ同期を実現します。

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

このスクリプトを実行するには、以下の環境とファイルが必要です。

1.  **実行環境**:
    -   `symbol-shoestring` を使用して構築されたノード環境
    -   `docker` 及び `docker-compose`
    -   `wget`
    -   `pigz` (tarの並列解凍に使用)
        -   Debian/Ubuntu系: `sudo apt-get install pigz`
2.  **必要なファイル**:
    -   スクリプトを実行するディレクトリに、`symbol-shoestring`セットアップ時に生成された以下のファイルが存在すること。
        -   `shoestring.ini`
        -   `overrides.ini`
        -   `docker-compose.yaml`
        -   `venv` フォルダ (Python仮想環境)

---

## 使い方 (Usage)

1.  **スクリプトのダウンロードと配置**:
    まず、`git clone`でリポジトリを任意の場所にダウンロードします。
    ```sh
    git clone https://github.com/MassFactory/shoestring_data_sync.git
    ```
    次に、ダウンロードされたフォルダの中から`shoestring_data_sync.sh`スクリプトを、あなたの**`symbol-shoestring`をインストールしたフォルダ**（`docker-compose.yaml`などがある場所）に移動またはコピーします。
    ```sh
    # 例: shoestringをインストールしたディレクトリにgitクローンした場合
    mv shoestring_data_sync/shoestring_data_sync.sh ../
    ```

2.  **スクリプトの実行準備**:
    `symbol-shoestring`をインストールしたフォルダに移動します。
    ```sh
    cd /path/to/your/shoestring/directory/
    ```
    スクリプトに実行権限を与えます。
    ```sh
    chmod +x shoestring_data_sync.sh
    ```

3.  **スクリプトの実行**:
    以下のコマンドでスクリプトを実行します。
    ```sh
    ./shoestring_data_sync.sh
    ```
    実行後、確認メッセージが表示されますので、`y`を入力して処理を続行してください。処理の進捗は画面に表示され、同時にログファイルにも記録されます。

---

## 注意事項 (Important Notes)

-   **データの上書き**: このスクリプトを実行すると、既存の`dbdata`および`data`ディレクトリ内のブロックチェーンデータは**完全に削除され**、ダウンロードした新しいデータに置き換えられます。
-   **自己責任での利用**: 本スクリプトの使用によって生じたいかなる損害についても、作成者は責任を負いません。内容を理解した上で、自己責任でご利用ください。
-   **データ提供元**: ブロックチェーン・スナップショットは[オープニングライン様](https://symbol-archive.opening-line.jp/)のアーカイブを利用させていただいております。

