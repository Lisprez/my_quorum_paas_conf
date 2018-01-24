#!/bin/bash

# rgs=("$@")
# args_num=$#

# for index in $(seq 0 $args_num); do
#     echo ${args[$index]};
# done

# initialize the script environment

./cleanup.sh

uid=`id -u`
gid=`id -g`
pwd=`pwd`

function echo_yellow() {
    local_text=$1
    echo -e "\033[33m $local_text \033[0m"
}

function echo_green() {
    local_text=$1
    echo -e "\033[32m $local_text \033[0m"
}

# create the directory tree for every node
# @1 \the number of nodes
function create_nodes_directory() { 
    echo_green '[1] Create directories for '$1' nodes.'
    for node_index in $(seq 1 $1); do
        qd=qdata_$node_index
        mkdir -p $qd/{logs,keys}
        mkdir -p $qd/dd/geth
    done
}

# create static_nodes.json file for every node
# @1 \the number of nodes
function create_static_nodes_json() {
    local_node_ips=$1
    local_node_num=$2
    echo_green '[2] Create Enodes and store them in static-nodes.json'

    echo "[" > static-nodes.json

    node_index=1
    for node_ip in ${local_node_ips[*]}; do
        qd=qdata_$node_index

        # Generate the node's Enode
        enode=`docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/bootnode -genkey /qdata/dd/nodekey -writeaddress`

        # Append enode to the static-nodes.json file
        sep=`[[ $node_index < $local_node_num ]] && echo ","`
        echo '  "enode://'$enode'@'$node_ip':30303?discport=0"'$sep >> static-nodes.json
        let node_index++
    done
    echo "]" >> static-nodes.json
}

# create genesis.json file and account
# @1 \the number of nodes
function create_account_and_genesis() {
    local_node_num=$1

    echo_green '[3] Creating accounts and genesis.json file.'

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
        sep=`[[ $node_index < $local_node_num ]] && echo ","`
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
    local_val=$1
    _ips=()
    local_n=0
    for elem in ${local_val[*]}; do
        _ips[$local_n]=$elem
        let local_n++
    done

    nodelist=
    n=1
    for ip in ${_ips[*]}
    do
        sep=`[[ $ip != ${_ips[0]} ]] && echo ","`
        nodelist=${nodelist}${sep}'"http://'${ip}':9000/"'
        let n++
    done

    echo_green '[4] Creating Quorum keys and finishing configuration.'
    n=1
    for ip in ${_ips[*]}
    do
        qd=qdata_$n

        cat templates/tm.conf \
            | sed "s/_NODEIP_/$ip/g" \
            | sed "s%_NODELIST_%$nodelist%g" \
                  > $qd/tm.conf

        cp genesis.json $qd/genesis.json
        cp static-nodes.json $qd/dd/static-nodes.json

        # Generate Quorum-related keys (used by Constellation)
        docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/constellation-enclave-keygen /qdata/keys/tm /qdata/keys/tma < /dev/null > /dev/null
        echo_yellow 'Node '$n' public key: '`cat $qd/keys/tm.pub`

        cp templates/start-node.sh $qd/start-node.sh
        chmod 755 $qd/start-node.sh

        let n++
    done
    rm -rf genesis.json static-nodes.json
}

# create the docker-compose file
# @1 \the image name
# @2 \the node ips
# @3 \the node ports
# @4 \the subnet of node
function create_compose_file() {

    local_image=$1
    local_ips=$2
    local_ports=$3
    local_subnet=$4

    cat > docker-compose.yml <<EOF
version: '2'
services:
EOF

    n=1
    for ip in ${local_ips[*]}
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
            - ${ports[$(expr $n - 1)]}:8545
        user: '$uid:$gid'
EOF
            let n++
    done

    cat >> docker-compose.yml <<EOF

networks:
    quorum_net:
        external:
            name: "$subnet"
EOF
}

## ./start.sh image_name network_segment ip1:port1 ip2:port2 ip3:port3 

args=("$@")
args_len=$#

if [ "$args_len" -eq 0 ]; then
    echo_yellow "usage: ./start.sh image_name subnet ip1:port1 ip2:port2 ip3:port3"
    echo_yellow "eg:    ./start.sh quorum 172.13.0.0/16 172.13.0.4:2000 172.13.0.5:2001 172.13.0.6:2002"
    exit
fi

image=${args[0]}
network_segment=${args[1]}
network_gateway=${args[2]}
nodes_num=$(expr $args_len - 3)
nodes=()
ips=()
ports=()

for index in $(seq 0 $(expr $nodes_num - 1)); do
    nodes[$index]=${args[$(expr $index + 3)]}
done

n=0
for node in ${nodes[*]}; do
    IFS=':' read -ra IP <<< $node
    ips[$n]=${IP[0]}
    ports[$n]=${IP[1]}
    let n++
done


printf " %-20s %-15s" image: $image
printf "\n"
printf " %-20s %-15s" network_seg: ${args[1]}
printf "\n"
printf " %-20s %-15s" network_gate: ${args[2]}
printf "\n"
printf " %-20s %-15s" nodes_number: $nodes_num
printf "\n"
printf " %-20s %-15s" ips: ${ips[*]}
printf "\n"
printf " %-20s %-15s" ports: ${ports[*]}
printf "\n"


## prepare the network environment
n=1
middle_content=`docker network ls | awk '{print $1}'`

catch_content=""
subnet=""

#docker network ls | awk '{print $1}' | 
while read line
 do 
	 echo $line
	 if [ "$line" == "NETWORK" ] 
	 then
		echo ""
	 else
		catch_content=`docker network inspect $line | grep $network_segment`
		if [ "$catch_content" == "" ]
		then
			let n++
		else
			break
		fi
	 fi
 done <<< $middle_content


 if [ "$catch_content" == "" ]
 then
	# create here
	subnet=`date +%Y%m%d%H%M%S`
     	docker network create --driver=bridge --subnet=$network_segment --gateway=$network_gateway $subnet
 else
	# get the name
	subnet=`docker network ls | awk '{print $2}' | sed -n "$(expr $n + 1)"p`
 fi

create_nodes_directory $nodes_num
create_static_nodes_json "${ips[*]}" $nodes_num
create_account_and_genesis $nodes_num 
finish_configure_nodes "${ips[*]}"
create_compose_file $image "${ips[*]}" "${ports[*]}" $subnet