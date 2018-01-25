#!/bin/bash

## mkdir group_x && cp -r stuff group_x
## ./setup.sh image_name network_sub netwrok_gate ip1:port1 ip2:port2
## ./check_start.sh ip1:port1 ip2:port2

args=("$@")
args_len=$#

ips=()
ports=()

n=0
for node in ${args[*]}; do
    IFS=':' read -ra IP <<< $node
    ips[$n]=${IP[0]}
    ports[$n]=${IP[1]}
    let n++
done

function echo_red() {
    local_text=$1
    echo -e "\E[1;31m $local_text \E[0m"
}

function echo_green() {
    local_text=$1
    echo -e "\033[32m $local_text \033[0m"
}

booted_failed_node=0
catch_content=""
for ip in ${ips[*]}; do
    catch_content=`docker ps | grep $ip`

    if [ "$catch_content" == "" ]
    then
        let booted_failed_node++
        echo_red "boot $ip failed"
    else
        echo_green "boot $ip success"
    fi
done

if [ "$booted_failed_node" == "$args_len" ]
then
    exit -1
elif [ "$booted_failed_node" == 0 ]
then
    exit 1
else
    exit 0
fi