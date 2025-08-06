#!/usr/bin/env bash

#================================================================================
#
# Symbol-shoestring ノード データ自動同期スクリプト
#
# [概要]
# このスクリプトは、symbol-shoestringで構築したSymbol (XYM) ノードのブロックチェーンデータを
# アーカイブサイトからダウンロードした最新のデータに置き換えます。
#
# [前提条件]
# 1. symbol-shoestringがインストールされたディレクトリで実行してください。
# 2. 以下の設定ファイルがスクリプトと同じディレクトリに存在すること:
#    - shoestring.ini
#    - overrides.ini
#    - docker-compose.yaml
# 3. `pigz`がインストールされていること (tarの並列解凍に使用します)。
#    (例: sudo apt-get install pigz)
# 4. `wget`, `docker` コマンドが利用可能であること。
#
# [注意事項]
# - 現在のブロックチェーンデータはすべて削除され、ダウンロードしたデータに置き換えられます。
# - 委任ハーベスティング設定(harvesters.dat)は、存在する場合に自動で
#   バックアップ・リストアされます。
# - 実行ログは `node_data_sync_YYYYMMDD_HHMMSS.log` という名前で自動保存されます。
#
#================================================================================

# --- ログ設定 ---
# ログファイル名に現在の日時を付与 (例: node_data_sync_20250805_154000.log)
readonly LOG_FILE="node_data_sync_$(date +%Y%m%d_%H%M%S).log"

# この行以降のすべての標準出力と標準エラー出力を、teeコマンド経由で
# ターミナルへの表示 と ログファイルへの保存 の両方に行う
exec > >(tee -a "${LOG_FILE}") 2>&1


# --- スクリプト設定 ---

# スクリプトがエラーで停止するように設定 (推奨)
set -euo pipefail

# 一時的にデータを保存するディレクトリ名
readonly BACKUP_DIR="back_data"

# ブロックチェーンデータのダウンロード元URL
readonly DATABASES_URL="https://symbol-archive.opening-line.jp/mainnet/mainnet.databases.tar.gz"
readonly DATA_URL="https://symbol-archive.opening-line.jp/mainnet/mainnet.data.tar.gz"

# Python仮想環境のコマンドパス (環境に合わせて変更してください)
readonly PYTHON_CMD="venv/bin/python3"


# --- 関数定義 ---

# 情報を標準出力に表示するためのヘルパー関数
log_info() {
    echo "INFO: $1"
}

# 処理のステップを示すためのヘッダー関数
log_step() {
    echo ""
    echo "======================================================================"
    echo "STEP: $1"
    echo "======================================================================"
}

# (★ここに追加★) 処理中にスピナーを表示するヘルパー関数
# 引数: バックグラウンドで実行されているプロセスのPID
show_spinner() {
    local pid=$1
    local spin='|/-\'
    local i=0
    # プロセスが終了するまでループ
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        # スピナーをアニメーション表示
        printf "\r[%c] 処理中..." "${spin:$i:1}"
        sleep 0.1
    done
    # 完了メッセージを表示
    printf "\r[✔] 完了        \n"
}


# 必須コマンドの存在をチェックする関数
check_dependencies() {
    log_info "必須コマンドの存在をチェックします..."
    local dependencies=("docker" "wget" "pigz" "${PYTHON_CMD}")
    local missing_deps=0
    for cmd in "${dependencies[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            echo "ERROR: 必須コマンドが見つかりません: ${cmd}"
            missing_deps=$((missing_deps + 1))
        fi
    done

    if [ ${missing_deps} -gt 0 ]; then
        echo "ERROR: 必要なコマンドがインストールされていないため、処理を中断します。"
        exit 1
    fi
    log_info "すべての必須コマンドが確認できました。"
}

# ユーザーに実行の最終確認を求める関数
confirm_execution() {
    log_step "実行確認"
    read -p "最新のブロックチェーンデータを投入します。現在のデータは削除されます。よろしいですか? (y/N): " yn
    if [[ ! "$yn" =~ ^[yY] ]]; then
        echo "処理を中止しました。"
        exit 0
    fi
}

# Symbolノード (Dockerコンテナ) を停止する関数
stop_node() {
    log_step "Symbolノードの停止"
    log_info "docker compose down を実行します..."
    docker compose down
}

# 委任者(ハーベスター)情報(harvesters.dat)をバックアップする関数
backup_harvesters_data() {
    log_step "委任者情報のバックアップ"
    if [ -f "data/harvesters.dat" ]; then
        log_info "既存の委任者データ(data/harvesters.dat)が見つかりました。バックアップします..."
        cp data/harvesters.dat .
        log_info "バックアップが完了しました: ./harvesters.dat"
    else
        log_info "バックアップ対象の委任者データ(data/harvesters.dat)は見つかりませんでした。処理をスキップします。"
    fi
}

# 不要になったDockerリソースを削除する関数
cleanup_docker_system() {
    log_step "Dockerシステムのクリーンアップ"
    log_info "停止中のコンテナ、未使用のネットワーク、ボリューム、イメージを削除します..."
    docker system prune -f
}

# symbol-shoestring のデータをリセットする関数
reset_shoestring_data() {
    log_step "symbol-shoestring データの初期化"
    log_info "shoestring reset-data を実行します..."
    "${PYTHON_CMD}" -m shoestring reset-data --config ./shoestring.ini --directory .
}

# ダウンロード用のディレクトリを準備する関数
prepare_backup_dir() {
    log_step "ダウンロード用ディレクトリの準備"
    if [ -d "${BACKUP_DIR}" ]; then
        log_info "${BACKUP_DIR}フォルダが存在するため、中身を一旦すべて削除します。"
        rm -rf "${BACKUP_DIR:?}"/*
    else
        log_info "${BACKUP_DIR}フォルダが存在しないため、新規に作成します。"
        mkdir "${BACKUP_DIR}"
    fi
    log_info "ディレクトリの準備が完了しました: ${BACKUP_DIR}"
}


# (★ここを置き換え★) 最新のブロックチェーンデータをダウンロードし、展開する関数
download_and_extract_data() {
    log_step "最新ブロックチェーンデータのダウンロードと展開"
    log_info "データの提供元: オープニングライン様 https://symbol-archive.opening-line.jp/"
    log_info "4つのステップで処理を実行します。これには時間がかかります..."
    echo "" # 読みやすくするために改行

    # --- ステップ1: データベースのダウンロード ---
    log_info "[1/4] データベースをダウンロードしています... (ファイルサイズ: 約2GB)"
    # wgetの出力を完全に抑制(-q)し、バックグラウンド(&)で実行
    (wget -q -P "./${BACKUP_DIR}" "${DATABASES_URL}") &
    show_spinner $! # バックグラウンドジョブのPIDをspinnerに渡す

    # --- ステップ2: ブロックデータのダウンロード ---
    log_info "[2/4] ブロックデータをダウンロードしています... (ファイルサイズ: 約70GB)"
    (wget -q -P "./${BACKUP_DIR}" "${DATA_URL}") &
    show_spinner $!

    # --- ステップ3: データベースの展開 ---
    log_info "[3/4] データベースを展開しています... (この処理はすぐに完了します)"
    # tarの出力を抑制し、バックグラウンドで実行
    (tar xf "./${BACKUP_DIR}/mainnet.databases.tar.gz" -C "./${BACKUP_DIR}/" -I pigz) &
    show_spinner $!

    # --- ステップ4: ブロックデータの展開 ---
    log_info "[4/4] ブロックデータを展開しています... (この処理が最も時間がかかります)"
    (tar xf "./${BACKUP_DIR}/mainnet.data.tar.gz" -C "./${BACKUP_DIR}/" -I pigz) &
    show_spinner $!

    log_info "データのダウンロードと展開がすべて完了しました。"
}


# 展開したデータを適切な場所に移動する関数
move_data_to_node() {
    log_step "展開済みデータの移動"
    log_info "ダウンロードしたデータをsymbol-shoestringのディレクトリに移動します..."
    mv -f "./${BACKUP_DIR}/databases/db/"* dbdata/
    mv -f "./${BACKUP_DIR}/data/"* data/
    log_info "データの移動が完了しました。"
}

# 委任者(ハーベスター)情報(harvesters.dat)をリストアする関数
restore_harvesters_data() {
    log_step "委任者情報のリストア"
    if [ -f "./harvesters.dat" ]; then
        log_info "バックアップされた委任者データ(./harvesters.dat)が見つかりました。リストアします..."
        cp ./harvesters.dat data/
        log_info "リストアが完了しました: data/harvesters.dat"
    else
        log_info "リストア対象の委任者データ(./harvesters.dat)は見つかりませんでした。処理をスキップします。"
    fi
}

# Symbolノードを起動する関数
start_node() {
    log_step "Symbolノードの起動"
    log_info "docker compose up -d を実行してバックグラウンドでノードを起動します..."
    docker compose up -d
}

# ノードのヘルスチェックを行う関数
health_check() {
    log_step "ヘルスチェック"
    log_info "ノードの起動を安定させるため60秒待機します..."
    sleep 60
    log_info "ヘルスチェックを実行します..."
    "${PYTHON_CMD}" -m shoestring health --config ./shoestring.ini --directory .
}


# --- メイン処理 ---
main() {
    check_dependencies
    confirm_execution

    log_info "処理を開始します。"

    stop_node
    backup_harvesters_data
    cleanup_docker_system
    reset_shoestring_data
    prepare_backup_dir
    download_and_extract_data
    move_data_to_node
    restore_harvesters_data
    start_node
    health_check

    log_info "すべての処理が完了しました。"
    log_info "ログは ${LOG_FILE} に保存されました。"
}

# スクリプトの実行開始
main


