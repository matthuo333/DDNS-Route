#!/usr/bin/env bash
#!/bin/bash -e
#set -o errexit
#set -o nounset
#set -o pipefail

# Automatically update your CloudFlare DNS record to the IP, Dynamic DNS
# Can retrieve cloudflare Domain id and list zone's, because, lazy

# Place at:
# curl https://raw.githubusercontent.com/yulewang/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh > /usr/local/bin/cf-ddns.sh && chmod +x /usr/local/bin/cf-ddns.sh
# run `crontab -e` and add next line:
# */1 * * * * /usr/local/bin/cf-ddns.sh >/dev/null 2>&1
# or you need log:
# */1 * * * * /usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1


# Usage:
# cf-ddns.sh -k cloudflare-api-key \
#            -u user@example.com \
#            -h host.example.com \     # fqdn of the record you want to update
#            -z example.com \          # will show you all zones if forgot, but you need this
#            -t A|AAAA                 # specify ipv4/ipv6, default: ipv4

# Optional flags:
#            -f false|true \           # force dns update, disregard local stored ip

# default config

HOME="/home/matt"   #add by matt 20230819

# API key, see https://www.cloudflare.com/a/account/my-account,
# incorrect api-key results in E_UNAUTH error
CFKEY=xxxxxxxxx
# Username, eg: user@example.com
CFUSER=xxxxxx@qq.com

# Zone name, eg: example.com
CFZONE_NAME=xxxxx.space

# Hostname to update, eg: homeserver.example.com
CFRECORD_NAME=ddns.xxxxx.space

# Record type, A(IPv4)|AAAA(IPv6), default IPv4
CFRECORD_TYPE=A

# Cloudflare TTL for record, between 120 and 86400 seconds
CFTTL=120

# Ignore local file, update ip anyway
FORCE=false

WANIPSITE="http://ipv4.icanhazip.com"
WANIPSITE_NX="ipv4.icanhazip.com" # convient to eque value by matt

#For routes change by matt 2023 08 19
# Define the routes you want to add
#default_route="default via 172.20.10.13 dev enp0s3"
#custom_route="104.16.0.0/16 via 172.20.10.1 dev enp0s3" # Notice: ipv4.icanhazip.com could changed its IP, like 104.18 turn into 104.16. So to modify by hand    by matt 2024 03 30

ROUTER="10.0.0.106"
GATEWAY="10.0.0.1"
INTERFACE="enp0s3"

#echo "matt000"
current_first_hop=$(ip route show | grep "default" | awk '{print $3}' | head -n 1)
echo "current_first_hop value: $current_first_hop"
#echo "matt111"

if [ -z "$current_first_hop" ]; then
    echo "No default route found. Adding default route with gateway $ROUTER"
    sudo ip route add default via "$ROUTER" dev "$INTERFACE"
else
    echo "Default route found. Removing existing default route and adding new route with gateway $ROUTER"
    sudo ip route del default dev "$INTERFACE"
    sudo ip route add default via "$ROUTER" dev "$INTERFACE"
fi


#echo "matt222"
current_captureip_route=$(ip route show | grep "104.16.0.0" | awk '{print $3}')
#echo "matt333"
if [ -z "$current_captureip_route" ]; then
    echo "Fourth hop not found. Adding fourth hop with gateway $GATEWAY"
    sudo ip route add 104.16.0.0/16 via "$GATEWAY" dev "$INTERFACE"
elif [ "$current_captureip_route" != "$GATEWAY" ]; then
    echo "Updating fourth hop gateway to $GATEWAY"
    sudo ip route del 104.16.0.0/16 via "$current_captureip_route" dev "$INTERFACE"
    sudo ip route add 104.16.0.0/16 via "$GATEWAY" dev "$INTERFACE"
else
    echo "Fourth hop gateway is already set to $GATEWAY"
fi

echo "Route table updated successfully."


# add for flow dispatched by matt
IP_ADDRESS=$(nslookup ${WANIPSITE_NX} | grep 'Address:' | awk -F " " 'NR==2{print $2}')

DOMAIN_AND_PORT="${WANIPSITE_NX}:443"

#curl --resolve "$DOMAIN_AND_PORT:$IP_ADDRESS" ${WANIPSITE}
#######

# Site to retrieve WAN ip, other examples are: bot.whatismyipaddress.com, https://api.ipify.org/ ...
if [ "$CFRECORD_TYPE" = "A" ]; then
  :
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  echo "$CFRECORD_TYPE specified is invalid, CFRECORD_TYPE can only be A(for IPv4)|AAAA(for IPv6)"
  exit 2
fi

# get parameter
while getopts k:u:h:z:t:f: opts; do
  case ${opts} in
    k) CFKEY=${OPTARG} ;;
    u) CFUSER=${OPTARG} ;;
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    t) CFRECORD_TYPE=${OPTARG} ;;
    f) FORCE=${OPTARG} ;;
  esac
done

# If required settings are missing just exit
if [ "$CFKEY" = "" ]; then
  echo "Missing api-key, get at: https://www.cloudflare.com/a/account/my-account"
  echo "and save in ${0} or using the -k flag"
  exit 2
fi
if [ "$CFUSER" = "" ]; then
  echo "Missing username, probably your email-address"
  echo "and save in ${0} or using the -u flag"
  exit 2
fi
if [ "$CFRECORD_NAME" = "" ]; then 
  echo "Missing hostname, what host do you want to update?"
  echo "save in ${0} or using the -h flag"
  exit 2
fi

# If the hostname is not a FQDN
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [ -z "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  echo " => Hostname is not a FQDN, assuming $CFRECORD_NAME"
fi

# Get current and old WAN ip
#WAN_IP=`curl -s ${WANIPSITE}`
WAN_IP=`curl -s --resolve "$DOMAIN_AND_PORT:$IP_ADDRESS" ${WANIPSITE}` # 按照curl 特定解析方案获得本地IP， 但是IP 或许变化后，需要手动放入route
echo "matt : ${WAN_IP}"

WAN_IP_FILE=$HOME/.cf-wan_ip_$CFRECORD_NAME.txt
if [ -f $WAN_IP_FILE ]; then
  OLD_WAN_IP=`cat $WAN_IP_FILE`
else
  echo "No file, need IP"
  OLD_WAN_IP=""
fi

# If WAN IP is unchanged an not -f flag, exit here
if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  echo "WAN IP Unchanged, to update anyway use flag -f true"
  exit 0
fi

# Get zone_identifier & record_identifier
ID_FILE=$HOME/.cf-id_$CFRECORD_NAME.txt
if [ -f $ID_FILE ] && [ $(wc -l $ID_FILE | cut -d " " -f 1) == 4 ] \
  && [ "$(sed -n '3,1p' "$ID_FILE")" == "$CFZONE_NAME" ] \
  && [ "$(sed -n '4,1p' "$ID_FILE")" == "$CFRECORD_NAME" ]; then
    CFZONE_ID=$(sed -n '1,1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2,1p' "$ID_FILE")
else
    echo "Updating zone_identifier & record_identifier"
    CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1 )
    CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json"  | grep -Po '(?<="id":")[^"]*' | head -1 )
    echo "$CFZONE_ID" > $ID_FILE
    echo "$CFRECORD_ID" >> $ID_FILE
    echo "$CFZONE_NAME" >> $ID_FILE
    echo "$CFRECORD_NAME" >> $ID_FILE
fi

# If WAN is changed, update cloudflare
echo "Updating DNS to $WAN_IP"

RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  -H "X-Auth-Email: $CFUSER" \
  -H "X-Auth-Key: $CFKEY" \
  -H "Content-Type: application/json" \
  --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL}")

if [ "$RESPONSE" != "${RESPONSE%success*}" ] && [ "$(echo $RESPONSE | grep "\"success\":true")" != "" ]; then
  echo "Updated succesfuly!"
  echo $WAN_IP > $WAN_IP_FILE
  exit
else
  echo 'Something went wrong :('
  echo "Response: $RESPONSE"
  exit 1
fi
