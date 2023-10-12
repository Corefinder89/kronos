#!/bin/bash

echo "Listing all droplets"

metadata=$(curl -X GET "https://api.digitalocean.com/v2/droplets" \
	-H "Authorization: Bearer $DO_API_ACCESS_TOKEN")

dropletids=$(echo "$metadata" | jq -r '.droplets[].id')

for droplet in $dropletids; do
  curl -X DELETE \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DO_API_ACCESS_TOKEN" \
  "https://api.digitalocean.com/v2/droplets/$droplet";
done

if [ $? -eq 0 ]; then
    echo "All droplets destroyed"
else
    echo "Exit status failure"
fi
