#!/bin/bash

echo "Listing all droplets"

metadata_ids=$(curl -X GET "https://api.digitalocean.com/v2/droplets" \
	-H "Authorization: Bearer $DO_API_ACCESS_TOKEN")

dropletids=$(echo "$metadata" | jq -r '.droplets[].id')

# Delete droplets from remote [Digital ocean]
for droplet in $dropletids; do
  curl -X DELETE \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DO_API_ACCESS_TOKEN" \
  "https://api.digitalocean.com/v2/droplets/$droplet";
done

# Delete local configurations
dropletnames=$(docker-machine ls | awk 'NR > 1 {print $1}')
docker-machine rm -f $dropletnames

if [ $? -eq 0 ]; then
    echo "All droplets destroyed from remote and the local"
else
    echo "Exit status failure"
fi
