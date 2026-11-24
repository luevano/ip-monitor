#!/usr/bin/bash
#
# ip-monitor: keep the Vultr A/AAAA records in sync with this host's public
# addresses, and remove IPv6 addresses left over from an old ISP prefix.
#
# Usage: ip-monitor [--dry-run]
#   --dry-run  only report: no DNS update, no address removal, no Discord
#              post, no state written, and the API is only read (GET).
#
# Paths (first one set wins):
#   config: $IP_MONITOR_CONFIG, $CREDENTIALS_DIRECTORY/config.sh,
#           /etc/ip-monitor/config.sh
#   state:  $IP_MONITOR_STATE, $STATE_DIRECTORY, /var/lib/ip-monitor

set -uo pipefail

DRY_RUN=0
case "${1:-}" in
	"") ;;
	--dry-run) DRY_RUN=1 ;;
	*) echo "Usage: ${0##*/} [--dry-run]" >&2; exit 2 ;;
esac

CONFIG="${IP_MONITOR_CONFIG:-${CREDENTIALS_DIRECTORY:-/etc/ip-monitor}/config.sh}"
STATE_DIR="${IP_MONITOR_STATE:-${STATE_DIRECTORY:-/var/lib/ip-monitor}}"

if [ ! -r "$CONFIG" ]; then
	echo "Can't read config file: $CONFIG" >&2
	exit 2
fi
# shellcheck disable=SC1090
source "$CONFIG"

for var in API_URL API_SECRET DOMAIN VULTR_API_URL VULTR_API_KEY; do
	if [ -z "${!var:-}" ]; then
		echo "Missing $var in $CONFIG" >&2
		exit 2
	fi
done

# optional settings
: "${DISCORD_USERNAME:=IP Monitor}"
: "${DISCORD_WEBHOOK:=}"
: "${SPEEDTEST_SERVER_ID:=}"
: "${VULTR_RECORD_ID_AAAA:=}"
: "${VULTR_API_URL_AAAA:=}"
: "${IPV6_ENABLED:=1}"
: "${IPV6_INTERFACE:=}"
: "${IPV6_REMOVE_STALE:=1}"
: "${IPV6_CHECK_URL:=$API_URL}"

C_GOLD=15844367
C_GREEN=5763719
C_BLUE=3447003
C_PURPLE=10181046
C_ORANGE=15105570
C_RED=15548997

CURL=(curl -sS --connect-timeout 10 --max-time 30)

# results, filled in by ipv4_run and ipv6_run
IPV4_CURRENT=""
IPV4_CHANGED=0
IPV6_CURRENT=""
IPV6_CHANGED=0
IPV6_REMOVED=()
ERRORS=()
VULTR_ERROR=""

log ()
{
	echo "$*"
}

state_get ()
{
	cat "$STATE_DIR/$1" 2>/dev/null || true
}

state_set ()
{
	[ "$DRY_RUN" -eq 1 ] && return 0
	mkdir -p "$STATE_DIR" && printf '%s\n' "$2" > "$STATE_DIR/$1"
}

# Secrets go to curl through file descriptors, not arguments, so they don't
# show up in the process list.
vultr_auth ()
{
	printf 'Authorization: Bearer %s\n' "$VULTR_API_KEY"
}

# $1 = record URL; prints the record's current data
vultr_get ()
{
	"${CURL[@]}" -4 "$1" -H @<(vultr_auth) | jq -r '.record.data // empty' 2>/dev/null
}

# $1 = record URL, $2 = new address; Vultr answers 204 with no body on success
vultr_patch ()
{
	local body resp rc
	body="$(jq -n --arg ip "$2" '{name: "", data: $ip, ttl: 300, priority: 0}')"
	resp="$("${CURL[@]}" -4 -X PATCH "$1" -H @<(vultr_auth) \
		-H "Content-Type: application/json" -d "$body" -w '\n%{http_code}' 2>&1)"
	rc=$?
	VULTR_ERROR="${resp%$'\n'*}"
	[ "$rc" -eq 0 ] && [ "${resp##*$'\n'}" = "204" ]
}

# Bring one DNS record in line with an address.
# $1 = state key, $2 = record URL, $3 = address, $4 = label for the logs
# Returns 0 = nothing to do, 10 = record updated, 1 = update failed.
# The state is only written once Vultr has the address, so a failed update is
# retried on the next run.
sync_record ()
{
	local last
	last="$(state_get "$1")"
	[ "$last" = "$3" ] && return 0

	# no state yet (first run): don't update a record that is already right
	if [ -z "$last" ] && [ "$(vultr_get "$2")" = "$3" ]; then
		log "$4: record already has $3, saving state."
		state_set "$1" "$3"
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "$4: [dry-run] would update the record from '${last:-unknown}' to $3."
		return 10
	fi

	if vultr_patch "$2" "$3"; then
		log "$4: record updated from '${last:-unknown}' to $3."
		state_set "$1" "$3"
		return 10
	fi
	log "$4: failed to update the record to $3. Vultr said: $VULTR_ERROR"
	ERRORS+=("Failed to update the $4 record to $3 in Vultr: $VULTR_ERROR")
	return 1
}

ipv4_run ()
{
	local resp code ip
	if [ "$DRY_RUN" -eq 1 ]; then
		resp="$("${CURL[@]}" -4 "$API_URL")"
	else
		resp="$(jq -n --arg name "$DOMAIN" --arg secret "$API_SECRET" \
			'{name: $name, secret: $secret}' \
			| "${CURL[@]}" -4 -X PUT "$API_URL" -H "Content-Type: application/json" -d @-)"
	fi
	code="$(jq -r '.status_code // empty' <<< "$resp" 2>/dev/null)"
	ip="$(jq -r '.ip // empty' <<< "$resp" 2>/dev/null)"

	# the response isn't logged as a whole: it can contain the secret
	if [[ ! "$code" =~ ^20[01]$ || ! "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
		log "IPv4: unexpected API response (status_code '${code:-none}')."
		ERRORS+=("Unexpected IP Monitor API response (status_code '${code:-none}').")
		return 1
	fi

	IPV4_CURRENT="$ip"
	log "IPv4: public address is $ip."
	sync_record ipv4 "$VULTR_API_URL" "$ip" "A"
	[ $? -eq 10 ] && IPV4_CHANGED=1
	return 0
}

# $1 = local IPv6 address; true if a request sent from it gets an answer
ipv6_works ()
{
	"${CURL[@]}" -6 --interface "$1" --max-time 8 -o /dev/null "$IPV6_CHECK_URL" \
		< /dev/null 2> /dev/null
}

ipv6_run ()
{
	local iface addr plen dynamic last entry
	local good=() bad=()

	[ "$IPV6_ENABLED" = "1" ] || return 0

	iface="$IPV6_INTERFACE"
	[ -n "$iface" ] || iface="$(ip -6 -j route show default | jq -r '.[0].dev // empty')"
	if [ -z "$iface" ]; then
		log "IPv6: no default route, skipping."
		return 0
	fi

	# Public (2000::/3) addresses that are ready to use, best candidate for
	# the AAAA record first: not temporary, not deprecated, SLAAC (/64).
	while IFS=$'\t' read -r addr plen dynamic; do
		[ -n "$addr" ] || continue
		if ipv6_works "$addr" || ipv6_works "$addr"; then
			good+=("$addr")
		else
			bad+=("$addr/$plen $dynamic")
		fi
	done < <(ip -6 -j addr show dev "$iface" scope global | jq -r '
		[.[].addr_info[]
			| select(.family == "inet6" and .scope == "global")
			| select(((.tentative // false) or (.dadfailed // false)) | not)
			| select(.local | test("^[23]"))]
		| sort_by([(.temporary // false), (.deprecated // false), (.prefixlen != 64)])
		| .[] | [.local, .prefixlen, (.dynamic // false)] | @tsv')

	if [ ${#good[@]} -eq 0 ]; then
		# no connectivity at all (or no address yet): nothing can be told apart
		log "IPv6: no working address on $iface (${#bad[@]} tried), leaving everything as is."
		return 0
	fi

	# With a working address present, the ones that don't work are leftovers
	# from an old prefix. Only addresses the network handed out are removed.
	for entry in "${bad[@]}"; do
		addr="${entry% *}"
		dynamic="${entry#* }"
		if [ "$dynamic" != "true" ] || [ "$IPV6_REMOVE_STALE" != "1" ]; then
			log "IPv6: $addr doesn't work, not removing it."
		elif [ "$DRY_RUN" -eq 1 ]; then
			log "IPv6: [dry-run] would remove stale address $addr."
		elif ip -6 addr del "$addr" dev "$iface"; then
			log "IPv6: removed stale address $addr."
			IPV6_REMOVED+=("$addr")
		else
			log "IPv6: couldn't remove stale address $addr (needs CAP_NET_ADMIN)."
			ERRORS+=("Couldn't remove stale IPv6 address $addr.")
		fi
	done

	# keep the published address for as long as it works
	last="$(state_get ipv6)"
	IPV6_CURRENT="${good[0]}"
	for addr in "${good[@]}"; do
		[ "$addr" = "$last" ] && IPV6_CURRENT="$addr"
	done
	log "IPv6: public address is $IPV6_CURRENT (${#good[@]} working on $iface)."

	if [ -z "$VULTR_RECORD_ID_AAAA" ] || [ -z "$VULTR_API_URL_AAAA" ]; then
		log "IPv6: no AAAA record configured, not updating DNS."
		return 0
	fi
	sync_record ipv6 "$VULTR_API_URL_AAAA" "$IPV6_CURRENT" "AAAA"
	[ $? -eq 10 ] && IPV6_CHANGED=1
	return 0
}

# $1 = JSON array of embeds
discord_webhook ()
{
	local payload
	[ -n "$DISCORD_WEBHOOK" ] || return 0
	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] would post to Discord: $(jq -c '.' <<< "$1")"
		return 0
	fi
	payload="$(jq -n --arg username "$DISCORD_USERNAME" --argjson embeds "$1" \
		'{username: $username, embeds: $embeds}')"
	"${CURL[@]}" -o /dev/null -X POST -H "Content-Type: application/json" -d "$payload" \
		--config <(printf 'url = "%s"\n' "$DISCORD_WEBHOOK") \
		|| log "Failed to post to Discord."
}

# $1 = download speed in Mbps
get_embed_color ()
{
	awk -v s="$1" -v gold="$C_GOLD" -v green="$C_GREEN" -v blue="$C_BLUE" \
		-v purple="$C_PURPLE" -v orange="$C_ORANGE" -v red="$C_RED" 'BEGIN {
		if (s >= 300) print gold
		else if (s >= 250) print green
		else if (s >= 100) print blue
		else if (s >= 20) print purple
		else if (s >= 10) print orange
		else print red
	}'
}

# sets SPEEDTEST_DL and SPEEDTEST_UL (Mbps); false if there's no result
speedtest ()
{
	local out
	SPEEDTEST_DL=""
	SPEEDTEST_UL=""
	[ -n "$SPEEDTEST_SERVER_ID" ] || return 1
	command -v speedtest-go > /dev/null || return 1
	[ "$DRY_RUN" -eq 1 ] && return 1

	log "Performing Speedtest on server ID $SPEEDTEST_SERVER_ID."
	out="$(timeout 120 speedtest-go --server "$SPEEDTEST_SERVER_ID" --json)" || return 1
	# speedtest-go reports bytes per second
	SPEEDTEST_DL="$(jq -r '.servers[0].dl_speed // empty' <<< "$out" 2>/dev/null \
		| awk '{printf "%.2f", $1 / 125000}')"
	SPEEDTEST_UL="$(jq -r '.servers[0].ul_speed // empty' <<< "$out" 2>/dev/null \
		| awk '{printf "%.2f", $1 / 125000}')"
	[ -n "$SPEEDTEST_DL" ] && [ -n "$SPEEDTEST_UL" ]
}

notify ()
{
	local now color fields removed
	now="$(date -Iseconds)"

	if [ ${#ERRORS[@]} -gt 0 ]; then
		discord_webhook "$(jq -n --arg title "$DOMAIN" --arg ts "$now" \
			--argjson color "$C_RED" '{color: $color, title: $title,
			description: ($ARGS.positional | join("\n")), timestamp: $ts} | [.]' \
			--args "${ERRORS[@]}")"
	fi

	if [ "$IPV4_CHANGED" -eq 1 ]; then
		fields="$(jq -n --arg v4 "$IPV4_CURRENT" --arg v6 "${IPV6_CURRENT:-none}" '[
			{name: "IPv4", value: $v4, inline: true},
			{name: "IPv6", value: $v6, inline: true}]')"
		color="$C_BLUE"
		if speedtest; then
			color="$(get_embed_color "$SPEEDTEST_DL")"
			fields="$(jq --arg id "$SPEEDTEST_SERVER_ID" --arg dl "$SPEEDTEST_DL Mbps" \
				--arg ul "$SPEEDTEST_UL Mbps" '. + [
				{name: "Speedtest data", value: "", inline: false},
				{name: "Server ID", value: $id, inline: true},
				{name: "DL", value: $dl, inline: true},
				{name: "UL", value: $ul, inline: true}]' <<< "$fields")"
		fi
		log "Posting the IP change to Discord."
		discord_webhook "$(jq -n --arg title "$DOMAIN" --arg ts "$now" \
			--argjson color "$color" --argjson fields "$fields" \
			'[{color: $color, title: $title, description: "IP changed.",
			fields: $fields, timestamp: $ts}]')"
	elif [ "$IPV6_CHANGED" -eq 1 ] || [ ${#IPV6_REMOVED[@]} -gt 0 ]; then
		removed="none"
		[ ${#IPV6_REMOVED[@]} -gt 0 ] && removed="$(printf '%s\n' "${IPV6_REMOVED[@]}")"
		log "Posting the IPv6 change to Discord."
		discord_webhook "$(jq -n --arg title "$DOMAIN" --arg ts "$now" \
			--argjson color "$C_PURPLE" --arg v6 "${IPV6_CURRENT:-none}" \
			--arg removed "$removed" \
			'[{color: $color, title: $title, description: "IPv6 changed.",
			fields: [
				{name: "IPv6", value: $v6, inline: false},
				{name: "Stale addresses removed", value: $removed, inline: false}],
			timestamp: $ts}]')"
	fi
}

ipv6_run
ipv4_run
notify

if [ ${#ERRORS[@]} -gt 0 ]; then
	exit 1
fi
exit 0
