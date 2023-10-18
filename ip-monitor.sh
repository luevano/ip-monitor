#!/usr/bin/bash

# reading config
source ./config.sh

discord_webhook ()
{
	DISCORD_DATA="$(echo '{"username": "'"$DISCORD_USERNAME"'", "content": "'"$1"'"}')"
	curl -sX POST "$DISCORD_WEBHOOK" -H "Content-Type: application/json" -d "$DISCORD_DATA"
}


IP_MONITOR_DATA="$(echo '{"name": "'"$DOMAIN"'", "secret": "'"$API_SECRET"'"}')"
IP_MONITOR_RESPONSE="$(curl -4sX PUT "$API_URL" -H "Content-Type: application/json" -d "$IP_MONITOR_DATA")"
echo "$IP_MONITOR_RESPONSE" 
RESPONSE_CODE="$(echo "$IP_MONITOR_RESPONSE" | cut -d':' -f1)"

# notify in discord if new ip
if [ $RESPONSE_CODE -eq 200 ]; then
	echo "IP didn't change."
else
	echo "IP changed. Posting to Discord."
	discord_webhook "$IP_MONITOR_RESPONSE"

	echo "Getting IPv6."
	IPV6_MONITOR_RESPONSE="$(curl -6sX GET "$API_URL")"
	echo "$IPV6_MONITOR_RESPONSE" 

	NEW_IPV6="$(echo "$IPV6_MONITOR_RESPONSE" | jq '.ip' | tr -d '"')"
	discord_webhook "New IPv6: $NEW_IPV6"
fi

# update in vultr if new ip
if [ $RESPONSE_CODE -eq 201 ]; then
	NEW_IP="$(echo "$IP_MONITOR_RESPONSE" | cut -d'-' -f2)"

	VULTR_DATA="$(echo '{"name" : "", "data" : "'"$NEW_IP"'", "ttl" : 300, "priority" : 0}')"
	VULTR_RESPONSE="$(curl -6sX PATCH $VULTR_API_URL -H "Authorization: Bearer ${VULTR_API_KEY}" -H "Content-Type: application/json" -d "$VULTR_DATA")"

	if [ "$VULTR_RESPONSE" == "" ]; then
		MSG="New IP ($NEW_IP) for $DOMAIN updated in Vultr."
		echo "$MSG Posting to Discord."
		discord_webhook "$MSG"
	else
		MSG="Failed to update IP ($NEW_IP) for $DOMAIN in Vultr."
		echo "$MSG Posting to Discord. Response from Vultr API:"
		echo "$VULTR_RESPONSE"
		# just got to remove the double quotes as it messes with the json data
		VULTR_RESPONSE_SANITIZED="${VULTR_RESPONSE//'"'/""}"
		discord_webhook "$MGS Response from Vultr API: $VULTR_RESPONSE_SANITIZED"
	fi

	echo "Performing Speedtest on server ID $SPEEDTEST_SERVER_ID."
	SPEEDTEST_RESPONSE="$(speedtest-go --server "$SPEEDTEST_SERVER_ID" --json | jq '.user_info.IP,.servers[].dl_speed,.servers[].ul_speed' | tr '\n' ',' | tr -d '"' | rev | cut -c2- | rev)"
	SPEEDTEST_IP="$(echo "$SPEEDTEST_RESPONSE" | cut -d',' -f1)"
	SPEEDTEST_DL="$(echo "$SPEEDTEST_RESPONSE" | cut -d',' -f2)"
	SPEEDTEST_UL="$(echo "$SPEEDTEST_RESPONSE" | cut -d',' -f3)"

	MSG="Speedtest (ID $SPEEDTEST_SERVER_ID): IP: $SPEEDTEST_IP, DL: $SPEEDTEST_DL Mbps, UL: $SPEEDTEST_UL Mbps."
	echo "$MSG Posting to Discord."
	discord_webhook "$MSG"

fi

