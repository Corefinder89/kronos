#!/bin/bash

while getopts n:s: flag
do
	case "${flag}" in
		n) nodes=${OPTARG};;
		s) swarmnode=${OPTARG};;
	esac
done

echo "Setting up $nodes droplets===============================================>"

for i in `seq $nodes`; do
	docker-machine create \
	 --driver digitalocean \
     --digitalocean-image "ubuntu-20-04-x64" \
	 --digitalocean-region "nyc1" \
	 --digitalocean-size "s-4vcpu-8gb" \
     --digitalocean-access-token $DO_API_ACCESS_TOKEN \
     --engine-install-url "https://releases.rancher.com/install-docker/19.03.9.sh" \
    node-$i;
done

echo "Initialize $swarmnode as swarm node======================================>"

docker-machine ssh $swarmnode -- docker swarm init --advertise-addr $(docker-machine ip $swarmnode)
docker-machine ssh $swarmnode -- docker node update --availability drain node-1

echo "Adding nodes to the swarm node $swarmnode================================>"

TOKEN=`docker-machine ssh $swarmnode docker swarm join-token worker | grep token | awk '{ print $5 }'`

metadata=$(curl -X GET "https://api.digitalocean.com/v2/droplets" \
	-H "Authorization: Bearer $DO_API_ACCESS_TOKEN")

dropletnames=$(echo "$metadata" | jq -r '.droplets[].name')

for droplet in $dropletnames; do
	if [ $droplet == $swarmnode ]; then
		echo "Skipping $swarmnode==================================================>"
	else
		docker-machine ssh $droplet "docker swarm join --token ${TOKEN} $(docker-machine ip ${swarmnode}):2377"
	fi
done

echo "Deploying Selenium Grid to http://$(docker-machine ip $swarmnode):4444/grid/console"

eval $(docker-machine env $swarmnode)
docker stack deploy --compose-file="../distributed-test-setup/docker-compose.yml" selenium
docker service scale selenium_chrome=2 selenium_firefox=2
