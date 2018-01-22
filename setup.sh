#!/bin/bash

# rgs=("$@")
# args_num=$#

# for index in $(seq 0 $args_num); do
#     echo ${args[$index]};
# done

# create the directory tree for every node
# @1 \the number of nodes
function create_nodes_directory() {
    echo '[1] Create directories for '$1' nodes.'
    for node_index in $(seq 1 $1); do
        qd=qdata_$node_index
        mkdir -p $qd/{logs,keys}
        mkdir -p $qd/dd/geth
    done
}

# create static_nodes.json file for every node
# @1 \the number of nodes
function create_static_nodes_json() {
    echo '[2] Create Enodes and store them in static-nodes.json'

    echo "[" > static-nodes.json

    for node_index in $(seq 1 $1); do
        qd=qdata_$node_index

        # Generate the node's Enode
        enode=`docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/bootnode -genkey /qdata/dd/nodekey -writeaddress`

        # Append enode to the static-nodes.json file
        sep=`[[ $n < $nnodes ]] && echo ","`
        echo '  "enode://'$enode'@'$ip':30303?discport=0"'$sep >> static-nodes.json
    done
    echo "]" >> static-nodes.json
}

# create genesis.json file and account
# @1 \the number of nodes
function create_account_and_genesis() {
    echo '[3] Creating accounts and genesis.json file.'

    cat > genesis.json <<EOF
{
"alloc": {
EOF

    for node_index in $(seq 1 $1); do
        qd=qdata_$node_index
        touch $qd/passwords.txt

        # Generate account for the node
        account=`docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/geth --datadir=/qdata/dd --password /qdata/passwords.txt account new | cut -c 11-50`

        # Add the account to the genesis block so that it have some Ether initialized.
        sep=`[[ $n < $nnodes ]] && echo ","`
        cat >> genesis.json <<EOF
        "${account}": {
            "balance": "1000000000000000000000000000"
        }${sep}
EOF
    done

    cat >> genesis.json <<EOF
},
"coinbase": "0x0000000000000000000000000000000000000000",
"config": {
    "homesteadBlock": 0
},
"difficulty": "0x0",
"extraData": "0x",
"gasLimit": "0x2FEFD800",
"mixhash": "0x00000000000000000000000000000000000000647572616c65787365646c6578",
"nonce": "0x0",
"parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
"timestamp": "0x00"
}
EOF
}

# create node list for tm.conf and finish configure all the nodes
# @1 \the ip array that contains all the ips of all nodes
function finish_configure_nodes() {
    ips=$1
    nodelist=
    n=1
    for ip in ${ips[@]}
    do
        sep=`[[ $ip != ${ips[0]} ]] && echo ","`
        nodelist=${nodelist}${sep}'"http://'${ip}':9000/"'
        let n++
    done

    echo '[4] Creating Quorum keys and finishing configuration.'

    n=1
    for ip in ${ips[*]}
    do
        qd=qdata_$n

        cat templates/tm.conf \
            | sed s/_NODEIP_/${ips[$((n-1))]}/g \
            | sed s%_NODELIST_%$nodelist%g \
                  > $qd/tm.conf

        cp genesis.json $qd/genesis.json
        cp static-nodes.json $qd/dd/static-nodes.json

        # Generate Quorum-related keys (used by Constellation)
        docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/constellation-enclave-keygen /qdata/keys/tm /qdata/keys/tma < /dev/null > /dev/null
        echo 'Node '$n' public key: '`cat $qd/keys/tm.pub`

        cp templates/start-node.sh $qd/start-node.sh
        chmod 755 $qd/start-node.sh

        let n++
    done
    rm -rf genesis.json static-nodes.json
}

# create the docker-compose file
# @1 \the node ip array
function create_compose_file() {
    ips=$1

    cat > docker-compose.yml <<EOF
    version: '2'
    services:
EOF

    n=1
    for ip in ${ips[*]}
    do
        qd=qdata_$n

            cat >> docker-compose.yml <<EOF
            node_$n:
            image: $image
            volumes:
            - './$qd:/qdata'
            networks:
            quorum_net:
            ipv4_address: '$ip'
            ports:
            - $((n+22000)):8545
            user: '$uid:$gid'
EOF

            let n++
    done

    cat >> docker-compose.yml <<EOF

    networks:
    quorum_net:
    driver: bridge
    ipam:
    driver: default
    config:
    - subnet: $2
EOF
}

## ./start.sh image_name network_segment ip1:port1 ip2:port2 ip3:port3

args=("$@")
args_len=$#
image=${args[0]}
network_segment=${args[1]}
nodes_num=$(expr $args_len - 2)
nodes=()

for index in $(seq 0 $(expr $nodes_num - 1)); do
    echo ${args[$(expr $index + 2)]}
    nodes[$index]=${args[$(expr $index + 2)]}
done

echo image is: $image
echo network_segment: ${args[2]}
echo nodes number: $nodes_num

#create_nodes_directory $nodes_num
#create_static_nodes_json $nodes_num
#create_account_and_genesis $nodes_num
finish_configure_nodes "${nodes[*]}"
create_compose_file "${nodes[*]}" $network_segment
