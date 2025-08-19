#!/usr/bin/env bash

#================================================================================
#
# Symbol-shoestring ノード データ自動同期スクリプト
#
# [概要]
# このスクリプトは、symbol-shoestringのノードのブロックチェーンデータを、
# 最新のスナップショットに置き換えます。
#
# [使い方]
# 以下のいずれかの方法で実行してください。
#
# 方法1 (推奨):
# 1. ターミナルで、symbol-shoestringをインストールしたディレクトリに移動します。
#    例: cd /home/user/my-node
# 2. そのディレクトリで、このスクリプトを実行します。
#    例: ./shoestring_data_sync/shoestring_data_sync.sh
#
# 方法2:
# 1. ターミナルで、このスクリプトが置かれているディレクトリに移動します。
#    例: cd /home/user/my-node/shoestring_data_sync
# 2. そのディレクトリで、このスクリプトを実行します。
#    例: ./shoestring_data_sync.sh
#
# [注意事項]
# - ノードのブロックチェーンデータはすべて削除されます。
# - 委任ハーベスティング設定(harvesters.dat)は、存在する場合に自動で
#   バックアップ・リストアされます。
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
readonly DUAL_DATA_URL="https://catapultmainnetdata.s3.us-west-2.amazonaws.com/weekly/catapult_dual_data.tar.gz"

# --- グローバル変数 ---
TARGET_DIR=""
PYTHON_CMD=""
DOCKER_COMPOSE_CMD=""

TARGET_DOCKER_COMPOSE_PATH=""
TARGET_SHOESTRING_INI_PATH=""

# --- 関数定義 ---

# 情報を標準出力に表示する
log_info() {
    echo "INFO: $1"
}

# 処理のステップを示すヘッダー
log_step() {
    echo ""
    echo "======================================================================"
    echo "STEP: $1"
    echo "======================================================================"
}

# 処理中に進捗を表示する
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

# 操作対象のディレクトリを自動設定し、検証する
initialize_and_validate_paths() {
    log_step "操作対象ディレクトリの確認"

    local script_dir
    script_dir=$(cd "$(dirname "$0")" && pwd)

    # 最初に、親ディレクトリを試す (推奨される使い方)
    local potential_target_dir
    potential_target_dir=$(cd "${script_dir}/.." && pwd)
    log_info "親ディレクトリを操作対象として検証します: ${potential_target_dir}"

    if [ -f "${potential_target_dir}/docker-compose.yaml" ] && [ -f "${potential_target_dir}/shoestring.ini" ]; then
        TARGET_DIR="${potential_target_dir}"
    else
        # 親ディレクトリに必須ファイルがなければ、スクリプト実行ディレクトリ自体を試す
        log_info "親ディレクトリに必須ファイルが見つかりませんでした。スクリプト実行ディレクトリを検証します: ${script_dir}"
        if [ -f "${script_dir}/docker-compose.yaml" ] && [ -f "${script_dir}/shoestring.ini" ]; then
            TARGET_DIR="${script_dir}"
        else
            echo "エラー: 必須ファイル(docker-compose.yaml または shoestring.ini)が見つかりません。"
            echo "このスクリプトは、symbol-shoestringのインストール先、またはそのサブディレクトリから実行してください。"
            exit 1
        fi
    fi

    TARGET_DOCKER_COMPOSE_PATH="${TARGET_DIR}/docker-compose.yaml"
    TARGET_SHOESTRING_INI_PATH="${TARGET_DIR}/shoestring.ini"

    log_info "操作対象ディレクトリを自動設定しました: ${TARGET_DIR}"
    log_info "docker-compose.yaml: ${TARGET_DOCKER_COMPOSE_PATH}"
    log_info "shoestring.ini: ${TARGET_SHOESTRING_INI_PATH}"

    PYTHON_CMD="${TARGET_DIR}/venv/bin/python3"
    if [ ! -x "${PYTHON_CMD}" ]; then
        echo "エラー: Python仮想環境のコマンドが見つかりません: ${PYTHON_CMD}"
        exit 1
    fi

    log_info "操作対象ディレクトリは正常です。"
}

# 必須コマンドの存在をチェックする
check_dependencies() {
    log_info "必須コマンドの存在をチェックします..."
    local dependencies=("wget" "pigz" "git" "pv" "find")
    local missing_deps=0

    # docker と docker-compose の互換性をチェック
    if command -v "docker" &> /dev/null; then
        if command -v "docker compose" &> /dev/null; then
            DOCKER_COMPOSE_CMD="docker compose"
        elif command -v "docker-compose" &> /dev/null; then
            DOCKER_COMPOSE_CMD="docker-compose"
        else
            echo "ERROR: 'docker compose'または'docker-compose'コマンドが見つかりません。"
            missing_deps=$((missing_deps + 1))
        fi
    else
        echo "ERROR: 'docker'コマンドが見つかりません。"
        missing_deps=$((missing_deps + 1))
    fi

    # その他の依存関係をチェック
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

# ユーザーに実行の最終確認を求める
confirm_execution() {
    log_step "実行確認"
    read -p "指定されたノード (${TARGET_DIR}) のデータを更新します。現在のデータは削除されます。よろしいですか? (y/N): " yn
    if [[ ! "$yn" =~ ^[yY] ]]; then
        echo "処理を中止しました。"
        exit 0
    fi
}

# Symbolノードを停止する
stop_node() {
    log_step "Symbolノードの停止"
    log_info "${DOCKER_COMPOSE_CMD} down を実行します..."
    "${DOCKER_COMPOSE_CMD}" -f "${TARGET_DOCKER_COMPOSE_PATH}" down
}

# 委任者情報をバックアップする
backup_harvesters_data() {
    log_step "委任者情報のバックアップ"
    local harvester_file="${TARGET_DIR}/data/harvesters.dat"
    if [ -f "${harvester_file}" ]; then
        log_info "既存の委任者データ(${harvester_file})が見つかりました。バックアップします..."
        cp "${harvester_file}" .
        log_info "バックアップが完了しました: ./harvesters.dat"
    else
        log_info "バックアップ対象の委任者データは見つかりませんでした。処理をスキップします。"
    fi
}

# 不要になったDockerリソースを削除する
cleanup_docker_system() {
    log_step "Dockerシステムのクリーンアップ"
    log_info "停止中のコンテナ、未使用のネットワーク、ボリューム、イメージを削除します..."
    docker system prune -f > /dev/null 2>&1
}

# symbol-shoestring のデータをリセットする
reset_shoestring_data() {
    log_step "symbol-shoestring データの初期化"
    log_info "shoestring reset-data を実行します..."
    "${PYTHON_CMD}" -m shoestring reset-data --config "${TARGET_SHOESTRING_INI_PATH}" --directory "${TARGET_DIR}" > /dev/null 2>&1
}

# ダウンロード用のディレクトリを準備する
prepare_backup_dir() {
    log_step "ダウンロード用ディレクトリの準備"
    if [ -d "${BACKUP_DIR}" ]; then
        log_info "既存の ${BACKUP_DIR} フォルダを削除します。"
        rm -rf "${BACKUP_DIR}"
    fi
    
    log_info "${BACKUP_DIR}フォルダを新規に作成します。"
    mkdir "${BACKUP_DIR}"
    log_info "ディレクトリの準備が完了しました。(${BACKUP_DIR})"
}

# 最新のブロックチェーンデータをダウンロードし、展開する
download_and_extract_data() {
    log_step "最新ブロックチェーンデータのダウンロードと展開"
    log_info "データの提供元: 公式Github"
    echo ""

    local data_filename="catapult_dual_data.tar.gz"
    local data_filepath="./${BACKUP_DIR}/${data_filename}"

    log_info "[1/2] ブロックデータをダウンロードしています... (ファイルサイズ: 約80GB)"
    (wget -c -q -P "./${BACKUP_DIR}" "${DUAL_DATA_URL}") &
    show_progress $! "${data_filepath}"

    log_info "[2/2] ブロックデータを展開しています..."
    pv "${data_filepath}" 2>/dev/tty | pigz -dc | tar xf - -C "./${BACKUP_DIR}/"
    log_info " -> ブロックデータの展開が完了しました。"
    echo ""

    log_info "データのダウンロードと展開がすべて完了しました。"
}

# 展開したデータを移動する
move_data_to_node() {
    log_step "展開済みデータの移動"
    log_info "ダウンロードしたデータをターゲットディレクトリに移動します..."
    
    shopt -s nullglob
    mv -f "./${BACKUP_DIR}/databases/db/"* "${TARGET_DIR}/dbdata/"
    mv -f "./${BACKUP_DIR}/data/"* "${TARGET_DIR}/data/"
    shopt -u nullglob

    log_info "データの移動が完了しました。"
}

# 委任者情報をリストアする
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

# Symbolノードを起動する
start_node() {
    log_step "Symbolノードの起動"
    log_info "${DOCKER_COMPOSE_CMD} up -d を実行してバックグラウンドでノードを起動します..."
    "${DOCKER_COMPOSE_CMD}" -f "${TARGET_DOCKER_COMPOSE_PATH}" up -d
}

# ノードのヘルスチェックを行う
health_check() {
    log_step "ヘルスチェック"
    log_info "ノードの起動を安定させるため3分待機します..."
    sleep 180
    log_info "ヘルスチェックを実行します..."
    "${PYTHON_CMD}" -m shoestring health --config "${TARGET_SHOESTRING_INI_PATH}" --directory "${TARGET_DIR}"
    log_info "ヘルスチェックは正常に完了しました。"
}


# --- メイン処理 ---
main() {
    local start_time
    start_time=$(date +%s)

    initialize_and_validate_paths
    check_dependencies
    confirm_execution

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
