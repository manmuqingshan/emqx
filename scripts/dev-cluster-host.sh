#!/usr/bin/env bash

set -euo pipefail

## This starts configurable number of core and replicant nodes on the same host (not in docker).
## The nodes are named as core1, core2, replicant3, replicant4, ... where the number monotically increases.
## The number in node name is used as an offset for ekka to avoid clashing (see ekka_dist:offset/1).
## Nodes are started on loopback addresses starting from 127.0.0.1.
## The script uses sudo to add loopback aliases.
## The boot script is ./_build/emqx/rel/emqx/bin/emqx.
## The data and log directories are configured to use ./tmp/

# ensure dir
cd -P -- "$(dirname -- "$0")/../"

help() {
    echo
    echo "start | stop"
    echo "-h|--help: To display this usage info"
    echo "-n|--nodes: total number of nodes to start (default: 2)"
    echo "-c|--core_nodes: number of core nodes to start (default: 1)"
    echo "-b|--boot: boot script (default: ./_build/emqx/rel/emqx/bin/emqx)"
}

CMD="$1"
shift || true

export EMQX_NODE__COOKIE=test
BOOT_SCRIPT='./_build/emqx/rel/emqx/bin/emqx'
NODES=2
CORE_NODES=1

while [ "$#" -gt 0 ]; do
    case $1 in
        -h|--help)
            help
            exit 0
            ;;
        -n|--nodes)
            NODES="$2"
            shift 2
            ;;
        -c|--core-nodes)
            CORE_NODES="$2"
            shift 2
            ;;
        -b|--boot)
            BOOT_SCRIPT="$2"
            shift 2
            ;;
        *)
            echo "unknown option $1"
            exit 1
            ;;
    esac
done

REPLICANT_NODES=$((NODES - CORE_NODES))

# cannot use the same node name even IPs are different because Erlang distribution listens on 0.0.0.0
CORE_IDS=()
REPLICANT_IDS=()
SEEDS_ARRAY=()
for i in $(seq 1 "$CORE_NODES"); do
    SEEDS_ARRAY+=("core${i}@127.0.0.$i")
    CORE_IDS+=("$i")
done
for i in $(seq "$((CORE_NODES+1))" "$((CORE_NODES+REPLICANT_NODES))"); do
    REPLICANT_IDS+=("$i")
done

SEEDS="$(IFS=,; echo "${SEEDS_ARRAY[*]}")"

if [ "$CMD" = "stop" ]; then
    for id in "${REPLICANT_IDS[@]}"; do
        env EMQX_NODE_NAME="replicant${id}@127.0.0.$id" "$BOOT_SCRIPT" stop || true
    done
    for id in "${CORE_IDS[@]}"; do
        env EMQX_NODE_NAME="core${id}@127.0.0.$id" "$BOOT_SCRIPT" stop || true
    done
    exit 0
fi

start_cmd() {
    local role="$1"
    local id="$2"
    local ip="127.0.0.$id"
    local nodename="$role$id"
    local nodehome="$(pwd)/tmp/$nodename"
    mkdir -p "${nodehome}/data" "${nodehome}/log"
    cat <<-EOF
env DEBUG="${DEBUG:-0}" \
EMQX_NODE_NAME="$nodename@$ip" \
EMQX_CLUSTER__STATIC__SEEDS="$SEEDS" \
EMQX_CLUSTER__DISCOVERY_STRATEGY=static \
EMQX_NODE__DB_ROLE="$role" \
EMQX_LOG__FILE_HANDLERS__DEFAULT__LEVEL="${EMQX_LOG__FILE_HANDLERS__DEFAULT__LEVEL:-debug}" \
EMQX_LOG__FILE_HANDLERS__DEFAULT__FILE="${nodehome}/log/emqx.log" \
EMQX_LOG_DIR="${nodehome}/log" \
EMQX_NODE__DATA_DIR="${nodehome}/data" \
EMQX_LISTENERS__TCP__DEFAULT__BIND="$ip:1883" \
EMQX_LISTENERS__SSL__DEFAULT__BIND="$ip:8883" \
EMQX_LISTENERS__WS__DEFAULT__BIND="$ip:8083" \
EMQX_LISTENERS__WSS__DEFAULT__BIND="$ip:8084" \
EMQX_DASHBOARD__LISTENERS__HTTP__BIND="$ip:18083" \
"$BOOT_SCRIPT" start
EOF
}

start_node() {
    local cmd
    cmd="$(start_cmd "$1" "$2" | envsubst)"
    echo "$cmd"
    eval "$cmd"
}

for id in "${CORE_IDS[@]}"; do
    sudo ifconfig lo0 alias 127.0.0.$id up
    start_node core "$id" &
done

for id in "${REPLICANT_IDS[@]}"; do
    sudo ifconfig lo0 alias 127.0.0.$id up
    start_node replicant "$id" &
done
