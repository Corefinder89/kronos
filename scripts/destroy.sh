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
metadata_names=$(curl -X GET "https://api.digitalocean.com/v2/droplets" \
	-H "Authorization: Bearer $DO_API_ACCESS_TOKEN")

dropletnames=$(echo "$metadata" | jq -r '.droplets[].name')

for droplet in $dropletnames; do
	docker-machine rm -f droplet
  echo deleting $droplet
done

if [ $? -eq 0 ]; then
    echo "All droplets destroyed"
else
    echo "Exit status failure"
fi
