#!/usr/bin/env bash

#================================================================================
#
# Symbol-shoestring ノード データ自動同期スクリプト
#
# [概要]
# このスクリプトは、symbol-shoestringのインストール先ディレクトリ内で実行することで、
# そのノードのブロックチェーンデータを最新のスナップショットに置き換えます。
#
# [使い方]
# 1. ターミナルを開き、`cd`コマンドでsymbol-shoestringをインストールした
#    ディレクトリ（例: /home/user/my-node）に移動します。
#
# 2. そのディレクトリの中で、`git clone`コマンドを実行して、このリポジトリを
#    ダウンロードします。
#    `git clone https://github.com/MassFactory/shoestring_data_sync.git`
#
# 3. `shoestring_data_sync`という名前の新しいフォルダが作成されるので、
#    `cd`コマンドでその中に入ります。
#    `cd shoestring_data_sync`
#
# 4. 以下のコマンドを実行して、スクリプトに実行権限を与えます。
#    `chmod +x shoestring_data_sync.sh`
#
# 5. 最後に、以下のコマンドでスクリプトを実行します。
#    `./shoestring_data_sync.sh`
#
# [注意事項]
# - ノードのブロックチェーンデータはすべて削除されます。
# - 委任ハーベスティング設定(harvesters.dat)は、存在する場合に自動で
#    バックアップ・リストアされます。
# - 実行ログはスクリプトと同じディレクトリに自動保存されます。
#
#================================================================================

# --- ログ設定 ---
readonly LOG_FILE="node_data_sync_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- スクリプト設定 ---
set -euo pipefail

# 一時的にデータを保存するディレクトリ名 (スクリプトと同じ場所に作成)
readonly BACKUP_DIR="back_data"

# ブロックチェーンデータのダウンロード元URL
readonly DATABASES_URL="https://symbol-archive.opening-line.jp/mainnet/mainnet.databases.tar.gz"
readonly DATA_URL="https://symbol-archive.opening-line.jp/mainnet/mainnet.data.tar.gz"

# --- グローバル変数 ---
# スクリプトの親ディレクトリを操作対象とする
TARGET_DIR=""
PYTHON_CMD=""

# docker-compose.yaml と shoestring.ini のパスを自動設定するための変数
TARGET_DOCKER_COMPOSE_PATH=""
TARGET_SHOESTRING_INI_PATH=""

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

# 処理中に進捗を表示するヘルパー関数
show_progress() {
    local pid=$1
    local filepath=${2:-}
    local spin='|/-\'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        if [ -n "$filepath" ] && [ -f "$filepath" ]; then
            local size=$(ls -lh "$filepath" | awk '{print $5}')
            printf "\r[%c] 処理中... (現在サイズ: %s)  " "${spin:$i:1}" "$size"
        else
            printf "\r[%c] 処理中...  " "${spin:$i:1}"
        fi
        sleep 1
    done
    printf "\r[✔] 完了                                  \n"
}

# 操作対象のディレクトリを自動設定し、検証する関数
initialize_and_validate_paths() {
    log_step "操作対象ディレクトリの確認"

    # スクリプトが置かれているディレクトリの、さらに親のディレクトリを取得
    local script_dir
    script_dir=$(cd "$(dirname "$0")" && pwd)
    TARGET_DIR=$(cd "${script_dir}/.." && pwd)
    
    log_info "親ディレクトリを操作対象として設定します: ${TARGET_DIR}"

    # docker-compose.yaml を自動探索
    log_info "docker-compose.yaml を ${TARGET_DIR} 以下で探索します..."
    local found_docker_compose
    found_docker_compose=$(find "${TARGET_DIR}" -type f -name "docker-compose.yaml" -print -quit)
    if [ -n "${found_docker_compose}" ]; then
        TARGET_DOCKER_COMPOSE_PATH="${found_docker_compose}"
        log_info "見つかりました: ${TARGET_DOCKER_COMPOSE_PATH}"
    fi

    # shoestring.ini を自動探索
    log_info "shoestring.ini を ${TARGET_DIR} 以下で探索します..."
    local found_shoestring_ini
    found_shoestring_ini=$(find "${TARGET_DIR}" -type f -name "shoestring.ini" -print -quit)
    if [ -n "${found_shoestring_ini}" ]; then
        TARGET_SHOESTRING_INI_PATH="${found_shoestring_ini}"
        log_info "見つかりました: ${TARGET_SHOESTRING_INI_PATH}"
    fi

    # 必須ファイルの存在を確認
    if ! [ -f "${TARGET_DOCKER_COMPOSE_PATH}" ] || ! [ -f "${TARGET_SHOESTRING_INI_PATH}" ]; then
        echo "エラー: 必須ファイル(docker-compose.yaml または shoestring.ini)が見つかりません。"
        echo "このスクリプトは、symbol-shoestringのインストール先でcloneしたディレクトリ内から実行してください。"
        exit 1
    fi
    
    PYTHON_CMD="${TARGET_DIR}/venv/bin/python3"
    if [ ! -x "${PYTHON_CMD}" ]; then
        echo "エラー: Python仮想環境のコマンドが見つかりません: ${PYTHON_CMD}"
        exit 1
    fi
    
    log_info "操作対象ディレクトリは正常です。"
}


# 必須コマンドの存在をチェックする関数
check_dependencies() {
    log_info "必須コマンドの存在をチェックします..."
    local dependencies=("docker" "wget" "pigz" "git" "pv" "find")
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
    read -p "指定されたノード (${TARGET_DIR}) のデータを更新します。現在のデータは削除されます。よろしいですか? (y/N): " yn
    if [[ ! "$yn" =~ ^[yY] ]]; then
        echo "処理を中止しました。"
        exit 0
    fi
}

# Symbolノードを停止する関数
stop_node() {
    log_step "Symbolノードの停止"
    log_info "docker compose down を実行します..."
    # コマンドの出力を抑制し、ログをクリーンに保つ
    docker compose -f "${TARGET_DOCKER_COMPOSE_PATH}" down > /dev/null 2>&1
}

# 委任者情報をバックアップする関数
backup_harvesters_data() {
    log_step "委任者情報のバックアップ"
    local harvester_file="${TARGET_DIR}/data/harvesters.dat"
    if [ -f "${harvester_file}" ]; then
        log_info "既存の委任者データ(${harvester_file})が見つかりました。バックアップします..."
        # スクリプトの実行場所にコピー
        cp "${harvester_file}" .
        log_info "バックアップが完了しました: ./harvesters.dat"
    else
        log_info "バックアップ対象の委任者データは見つかりませんでした。処理をスキップします。"
    fi
}

# 不要になったDockerリソースを削除する関数
cleanup_docker_system() {
    log_step "Dockerシステムのクリーンアップ"
    log_info "停止中のコンテナ、未使用のネットワーク、ボリューム、イメージを削除します..."
    # コマンドの出力を抑制
    docker system prune -f > /dev/null 2>&1
}

# symbol-shoestring のデータをリセットする関数
reset_shoestring_data() {
    log_step "symbol-shoestring データの初期化"
    log_info "shoestring reset-data を実行します..."
    # コマンドの出力を抑制
    "${PYTHON_CMD}" -m shoestring reset-data --config "${TARGET_SHOESTRING_INI_PATH}" --directory "${TARGET_DIR}" > /dev/null 2>&1
}

# ダウンロード用のディレクトリを準備する関数
prepare_backup_dir() {
    log_step "ダウンロード用ディレクトリの準備"
    # back_data ディレクトリがなければ作成
    if [ ! -d "${BACKUP_DIR}" ]; then
        log_info "${BACKUP_DIR}フォルダが存在しないため、新規に作成します。"
        mkdir "${BACKUP_DIR}"
    fi

    # 展開済みの古いディレクトリがあれば削除し、ダウンロードファイル(.tar.gz)は保持する
    if [ -d "${BACKUP_DIR}/databases" ]; then
        log_info "展開済みの古い'databases'ディレクトリを削除します..."
        rm -rf "${BACKUP_DIR}/databases"
    fi
    if [ -d "${BACKUP_DIR}/data" ]; then
        log_info "展開済みの古い'data'ディレクトリを削除します..."
        rm -rf "${BACKUP_DIR}/data"
    fi

    log_info "ディレクトリの準備が完了しました。(${BACKUP_DIR})"
}

# 最新のブロックチェーンデータをダウンロードし、展開する関数
download_and_extract_data() {
    log_step "最新ブロックチェーンデータのダウンロードと展開"
    log_info "データの提供元: オープニングライン様 https://symbol-archive.opening-line.jp/"
    log_info "4つのステップで処理を実行します。これには時間がかかります..."
    echo ""

    local db_filename="mainnet.databases.tar.gz"
    local data_filename="mainnet.data.tar.gz"
    local db_filepath="./${BACKUP_DIR}/${db_filename}"
    local data_filepath="./${BACKUP_DIR}/${data_filename}"

    log_info "[1/4] データベースをダウンロードしています... (ファイルサイズ: 約10GB)"
    (wget -c -q -P "./${BACKUP_DIR}" "${DATABASES_URL}") &
    show_progress $! "${db_filepath}"

    log_info "[2/4] ブロックデータをダウンロードしています... (ファイルサイズ: 約80GB)"
    (wget -c -q -P "./${BACKUP_DIR}" "${DATA_URL}") &
    show_progress $! "${data_filepath}"

    log_info "[3/4] データベースを展開しています... (この処理はすぐに完了します)"
    # pvの進捗表示(stderr)を直接ターミナル(/dev/tty)に出力し、ログリダイレクトを回避します
    pv "${db_filepath}" 2>/dev/tty | pigz -dc | tar xf - -C "./${BACKUP_DIR}/"
    log_info " -> データベースの展開が完了しました。"
    echo ""

    log_info "[4/4] ブロックデータを展開しています... (この処理が最も時間がかかります)"
    pv "${data_filepath}" 2>/dev/tty | pigz -dc | tar xf - -C "./${BACKUP_DIR}/"
    log_info " -> ブロックデータの展開が完了しました。"
    echo ""

    log_info "データのダウンロードと展開がすべて完了しました。"
}

# 展開したデータを移動する関数
move_data_to_node() {
    log_step "展開済みデータの移動"
    log_info "ダウンロードしたデータをターゲットディレクトリに移動します..."
    mv -f "./${BACKUP_DIR}/databases/db/"* "${TARGET_DIR}/dbdata/"
    mv -f "./${BACKUP_DIR}/data/"* "${TARGET_DIR}/data/"
    log_info "データの移動が完了しました。"
}

# 委任者情報をリストアする関数
restore_harvesters_data() {
    log_step "委任者情報のリストア"
    if [ -f "./harvesters.dat" ]; then
        log_info "バックアップされた委任者データ(./harvesters.dat)が見つかりました。リストアします..."
        cp ./harvesters.dat "${TARGET_DIR}/data/"
        log_info "リストアが完了しました: ${TARGET_DIR}/data/harvesters.dat"
    else
        log_info "リストア対象の委任者データは見つかりませんでした。処理をスキップします。"
    fi
}

# Symbolノードを起動する関数
start_node() {
    log_step "Symbolノードの起動"
    log_info "docker compose up -d を実行してバックグラウンドでノードを起動します..."
    # コマンドの出力を抑制
    docker compose -f "${TARGET_DOCKER_COMPOSE_PATH}" up -d > /dev/null 2>&1
}

# ノードのヘルスチェックを行う関数
health_check() {
    log_step "ヘルスチェック"
    log_info "ノードの起動を安定させるため60秒待機します..."
    sleep 60
    log_info "ヘルスチェックを実行します..."
    # コマンドの出力を抑制
    "${PYTHON_CMD}" -m shoestring health --config "${TARGET_SHOESTRING_INI_PATH}" --directory "${TARGET_DIR}" > /dev/null 2>&1
    # 正常終了したことを示すメッセージを追加
    log_info "ヘルスチェックは正常に完了しました。"
}


# --- メイン処理 ---
main() {
    # (★変更★) 開始時刻を記録
    local start_time
    start_time=$(date +%s)

    # 最初に操作対象のディレクトリを自動で設定・検証
    initialize_and_validate_paths
    
    # 必須コマンドを確認
    check_dependencies
    
    confirm_execution

    # (★変更★) 開始時刻をログに出力
    log_info "処理を開始します。 (開始時刻: $(date -d "@${start_time}" '+%Y-%m-%d %H:%M:%S'))"

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

    # (★変更★) 終了時刻を記録し、所要時間を計算・表示
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(( (duration % 3600) / 60 ))
    local seconds=$((duration % 60))

    log_info "すべての処理が完了しました。 (終了時刻: $(date -d "@${end_time}" '+%Y-%m-%d %H:%M:%S'))"
    log_info "合計所要時間: ${hours}時間 ${minutes}分 ${seconds}秒"
    log_info "ログは ${LOG_FILE} に保存されました。"
}

# スクリプトの実行開始
main
