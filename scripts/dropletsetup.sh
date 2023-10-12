#!/bin/bash

echo "Setting up droplets"

for i in {1..5}; do
	docker-machine create \
	   --driver digitalocean \
     --digitalocean-image "ubuntu-20-04-x64" \
     --digitalocean-access-token $DO_API_ACCESS_TOKEN \
     --engine-install-url "https://releases.rancher.com/install-docker/19.03.9.sh" \
    node-$i;
done


echo "Initialize swarm node"

docker-machine ssh node-1 -- docker swarm init --advertise-addr $(docker-machine ip node-1)

docker-machine ssh node-1 -- docker node update --availability drain node-1

echo "Adding nodes to the swarm"

TOKEN=`docker-machine ssh node-1 docker swarm join-token worker | grep token | awk '{ print $5 }'`

docker-machine ssh node-2 "docker swarm join --token ${TOKEN} $(docker-machine ip node-1):2377"
docker-machine ssh node-3 "docker swarm join --token ${TOKEN} $(docker-machine ip node-1):2377"
docker-machine ssh node-4 "docker swarm join --token ${TOKEN} $(docker-machine ip node-1):2377"
docker-machine ssh node-5 "docker swarm join --token ${TOKEN} $(docker-machine ip node-1):2377"

# echo "Deploying Selenium Grid to http://$(docker-machine ip node-1):4444..."

# eval $(docker-machine env node-1)
# docker stack deploy --compose-file=docker-compose.yml selenium
# docker service scale selenium_chrome=2 selenium_firefox=2
