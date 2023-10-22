#!/usr/bin/bash

# reading config
source ./config.sh

C_GOLD="15844367"
C_GREEN="5763719"
C_BLUE="3447003"
C_PURPLE="10181046"
C_ORANGE="15105570"
C_RED="15548997"

discord_webhook ()
{
	DISCORD_DATA='{"username": "'"$DISCORD_USERNAME"'", "embeds": '"$1"'}'
	curl -sX POST "$DISCORD_WEBHOOK" -H "Content-Type: application/json" -d "$DISCORD_DATA"
}

# float greater or equal than
f_ge ()
{
	RESULT="$(echo "$1 >= $2" | bc -l)"
	if [ $RESULT -eq 0 ]; then
		return 1
	fi
	return 0
}

get_embed_color ()
{
	if f_ge "$1" "300.0"; then
		echo "$C_GOLD"
	elif f_ge "$1" "250.0"; then
		echo "$C_GREEN"
	elif f_ge "$1" "100.0"; then
		echo "$C_BLUE"
	elif f_ge "$1" "20.0"; then
		echo "$C_PURPLE"
	elif f_ge "$1" "10.0"; then
		echo "$C_ORANGE"
	else
		echo "$C_RED"
	fi
}


IP_MONITOR_DATA='{"name": "'"$DOMAIN"'", "secret": "'"$API_SECRET"'"}'
IP_MONITOR_RESPONSE="$(curl -4sX PUT "$API_URL" -H "Content-Type: application/json" -d "$IP_MONITOR_DATA")"
echo "IP Monitor API response: $IP_MONITOR_RESPONSE" 
RESPONSE_CODE="$(echo "$IP_MONITOR_RESPONSE" | jq '.status_code')"

if [ $RESPONSE_CODE -eq 200 ]; then
	echo "IP hasn't changed."
elif [ $RESPONSE_CODE -eq 201 ]; then
	echo "IP changed. Getting IPv6."
	IPV6_MONITOR_RESPONSE="$(curl -6sX GET "$API_URL")"
	echo "IP Monitor API response: $IPV6_MONITOR_RESPONSE" 

	IPV4="$(echo "$IP_MONITOR_RESPONSE" | jq '.ip' | tr -d '"')"
	IPV6="$(echo "$IPV6_MONITOR_RESPONSE" | jq '.ip' | tr -d '"')"

	VULTR_DATA="$(echo '{"name" : "", "data" : "'"$IPV4"'", "ttl" : 300, "priority" : 0}')"
	VULTR_RESPONSE="$(curl -6sX PATCH $VULTR_API_URL -H "Authorization: Bearer ${VULTR_API_KEY}" -H "Content-Type: application/json" -d "$VULTR_DATA")"
	
	if [ "$VULTR_RESPONSE" == "" ]; then
		MSG="New IP ($IPV4) for $DOMAIN updated in Vultr."
		echo "$MSG"
	else
		MSG="Failed to update IP ($IPV4) for $DOMAIN in Vultr. Response from Vultr API:"
		echo "$MSG $VULTR_RESPONSE"
		# just got to remove the double quotes as it messes with the json data
		VULTR_RESPONSE_SANITIZED="${VULTR_RESPONSE//'"'/""}"

		DISCORD_DATE="$(date +"%Y-%m-%dT%H:%M:%S%z")"
		discord_webhook '[{
		"color": "'"$C_RED"'",
		"title": "'"$DOMAIN"'",
		"description": "'"$MSG"' '"$VULTR_RESPONSE_SANITIZED"'",
		"timestamp": "'"$DISCORD_DATE"'"
		}]'
		exit 1
	fi
	
	echo "Performing Speedtest on server ID $SPEEDTEST_SERVER_ID."
	SPEEDTEST_RESPONSE="$(speedtest-go --server "$SPEEDTEST_SERVER_ID" --json | jq '.user_info.IP,.servers[].dl_speed,.servers[].ul_speed' | tr '\n' ',' | tr -d '"' | rev | cut -c2- | rev)"
	# SPEEDTEST_IP="$(echo "$SPEEDTEST_RESPONSE" | cut -d',' -f1)"
	SPEEDTEST_DL="$(echo "$SPEEDTEST_RESPONSE" | cut -d',' -f2)"
	SPEEDTEST_UL="$(echo "$SPEEDTEST_RESPONSE" | cut -d',' -f3)"
	
	echo "Finished tests. Posting to Discord."
	DISCORD_COLOR="$(get_embed_color "$SPEEDTEST_DL")"
	DISCORD_DATE="$(date +"%Y-%m-%dT%H:%M:%S%z")"
	discord_webhook '[{
	"color": "'"$DISCORD_COLOR"'",
	"title": "'"$DOMAIN"'",
	"description": "IP changed.",
	"fields": [
	  {"name": "IPv4", "value": "'"$IPV4"'", "inline": "true"},
	  {"name": "IPv6", "value": "'"$IPV6"'", "inline": "true"},
	  {"name": "Speedtest data", "value": "", "inline": "false"},
	  {"name": "Server ID", "value": "'"$SPEEDTEST_SERVER_ID"'", "inline": "true"},
	  {"name": "DL", "value": "'"$SPEEDTEST_DL"' Mbps", "inline": "true"},
	  {"name": "UL", "value": "'"$SPEEDTEST_UL"' Mbps", "inline": "true"}
	],
	"timestamp": "'"$DISCORD_DATE"'"
	}]'
else
	echo "Unexpected response."
fi
