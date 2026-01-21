#!/bin/bash

SCION_DNS_SERVER=71-2:0:4a,141.44.25.150
CONNECTION_TEST_TARGET=71-20965,10.0.2.1
DNS_TEST_TARGET=welcome.scion.host

WIDTH=80

release=$(lsb_release -d | cut -f2)
if [[ "$release" != "Ubuntu 24.04.3 LTS" ]]; then
    echo "This script only works on Ubuntu 24.04.3 LTS"
    exit 1
fi

echo "This script will configure your computer as a SCION end host with" \
"Scitra-TUN as SCION-IP translator." | fold -s -w $WIDTH

wsl=0
if which wslinfo > /dev/null; then
    wsl=1
    wsl_networking_mode=$(wslinfo --networking-mode)
    echo "WSL networking mode: $wsl_networking_mode"
    echo "It appears you are running WSL. It is recommended that you add"
    echo "[network]"
    echo "generateHosts = false"
    echo "generateResolvConf = false"
    echo "to /etc/wsl.conf and reboot before running this setup script."
fi

read -n1 -r -p "Proceed? (y/n) "; echo && [[ "$REPLY" == [yY] ]] || exit 1

#-------------------------------------------------------------------------------

echo -e "\n\033[1mStep 1: Install SCION\033[0m"
if [ ! -f /etc/apt/sources.list.d/scion-lcschulz.list ]; then
echo "Setting up the SCION repository"
set -e
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo curl -fsSL https://lcschulz.de/scion/gpg/scion-lcschulz -o /usr/share/keyrings/scion-lcschulz.gpg
sudo chmod a+r /usr/share/keyrings/scion-lcschulz.gpg
sudo tee /etc/apt/sources.list.d/scion-lcschulz.list <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/scion-lcschulz.gpg] https://lcschulz.de/scion/apt noble main
EOF
set +e
fi

sudo apt-get update
sudo apt-get install scion-daemon scion-tools scitra-tun scion++-tools jq moreutils

#-------------------------------------------------------------------------------

echo -e "\n\033[1mStep 2: (Optional) Set up Wireguard\033[0m"
echo "Do you want to set up a Wireguard VPN to connect to your AS?"
read -n1 -r -p "Set up Wireguard? (y/n) "; echo
if [[ "$REPLY" == [yY] ]]; then
    sudo apt-get install wireguard-tools
    while true; do
        read -ep "Path to wireguard configuration: " wg_conf
        if [[ -f "$wg_conf" ]]; then
            sudo cp "$wg_conf" /etc/wireguard/
            wg_conf=$(basename "$wg_conf")
            wg_unit=wg-quick@${wg_conf%.*}.service
            sudo systemctl enable $wg_unit
            sudo systemctl start $wg_unit
            break
        else
            echo "File not found"
            read -n1 -r -p "Try again? (y/n) "; echo && [[ "$REPLY" == [yY] ]] && continue
            echo "Not using Wireguard"
            break
        fi
    done
fi

#-------------------------------------------------------------------------------

function ask_for_bootstrap_server {
    echo "Please select a bootstrap server:"
    options=(
        "Enter a URL manually"
        "71-2:0:4a OvGU Magdeburg [https://ovgu.bootstrap.scion.host]"
    )
    select opt in "${options[@]}"; do
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -gt 0 ]] && [[ "$REPLY" -le 2 ]] then
            if [[ "$REPLY" -ne 1 ]]; then
                bootstrap=$(echo "$opt" | sed -E 's/.*\[(.*)\].*/\1/')
                return 0
            else
                break
            fi
        fi
    done
    echo "Please enter the HTTP(S) URL of the bootstrap server in your AS."
    read -ep "Bootstrap server: " bootstrap
    if [[ "$bootstrap" == http://* ]]; then
        echo "Downloading the TRC over an unencrypted connection may expose you" \
        "to man-in-the-middle attacks."
        read -n1 -r -p "Proceed over HTTP anyway? (y/n) "; echo && [[ "$REPLY" == [yY] ]] || return 0
    elif [[ ! "$bootstrap" == https://* ]]; then
        echo "The URL you enter should start with a scheme of https:// or http://"
        return 1
    fi
    return 0
}

echo -e "\n\033[1mStep 3: Configure SCION\033[0m"
echo "Configuring a SCION end host requires the current TRC of your home ISD" \
"and a topology.json file defining some important addresses in the local AS." \
"We will attempt to fetch this configuration from a SCION bootstrap server." \
| fold -s -w $WIDTH
while true; do
    ask_for_bootstrap_server || continue
    temp=$(mktemp -d)
    curl -fsSL "$bootstrap/topology" > "$temp/topology.json" || exit 1
    curl -fsSL "$bootstrap/trcs" > "$temp/trcs" || exit 1
    mkdir "$temp/certs"
    for trc in $(jq -r '.[].id|"isd\(.isd)-b\(.base_number)-s\(.serial_number)"' "$temp/trcs"); do
        curl -fsSL "$bootstrap/trcs/$trc/blob" -o "$temp/certs/${trc^^}.trc" || exit 1
    done
    for trc in $temp/certs/*.trc; do
        echo "### $(basename $trc) ###"
        scion-pki trc inspect "$trc"
    done
    echo "### Topology ###"
    jq . "$temp/topology.json"
    read -n1 -r -p "Install this configuration? (y/n) "; echo
    if [[ "$REPLY" == [yY] ]]; then
        sudo cp "$temp/topology.json" /etc/scion/topology.json
        sudo rm /etc/scion/certs/* 2> /dev/null
        sudo mkdir -p /etc/scion/certs
        sudo cp "$temp"/certs/*.trc /etc/scion/certs
        rm -r "$temp"
        break
    else
        rm -r "$temp"
        continue
    fi
done

echo "The TRC and topology.json file will get updated over time. In order for" \
"your host to continue functioning after an update, the new files must be" \
"fetched and installed." | fold -s -w $WIDTH
read -n1 -r -p "Do you want to install a script to do so in /usr/local/bin/update-scion? (y/n) "
echo
if [[ "$REPLY" == [yY] ]]; then
sudo sponge /usr/local/bin/update-scion <<EOF
#!/usr/bin/bash
set -e
if [[ \$(id -u) -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi
temp=\$(mktemp -d)
curl -fsSL "$bootstrap/topology" > "\$temp/topology.json" || exit 1
curl -fsSL "$bootstrap/trcs" > "\$temp/trcs" || exit 1
mkdir "\$temp/certs"
for trc in \$(jq -r '.[].id|"isd\(.isd)-b\(.base_number)-s\(.serial_number)"' "\$temp/trcs"); do
    curl -fsSL "$bootstrap/trcs/\$trc/blob" -o "\$temp/certs/\${trc^^}.trc" || exit 1
done
cp "\$temp/topology.json" /etc/scion/topology.json
mkdir -p /etc/scion/certs
cp \$temp/certs/*.trc /etc/scion/certs
rm -r "\$temp"
systemctl restart scion-daemon
EOF
sudo chmod +x /usr/local/bin/update-scion

printf "Do you want to set up a systemd timer that runs update-scion once per boot
and every passing day? (y/n) "
read -n1 -r; echo
if [[ "$REPLY" == [yY] ]]; then

sudo sponge /etc/systemd/system/update-scion.service <<EOF
[Unit]
Description=Fetch SCION AS configuration from bootstrap server

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /usr/local/bin/update-scion
EOF

sudo sponge /etc/systemd/system/update-scion.timer <<EOF
[Unit]
Description=Update SCION AS configuration

[Timer]
OnBootSec=1min
OnUnitActiveSec=1d

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload

fi
fi

echo "Patch scion-daemon dependencies"
sudo sponge /etc/systemd/system/scion-daemon.service <<EOF
[Unit]
Description=SCION Daemon
Documentation=https://docs.scion.org
After=${wg_unit:-network-online.target}
Wants=$wg_unit
StartLimitBurst=2
StartLimitInterval=1s

[Service]
Type=simple
User=scion
Group=scion
ExecStart=/usr/bin/scion-daemon --config /etc/scion/daemon.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload

echo "Enable and start scion-daemon"
sudo systemctl enable scion-daemon.service
if [ -f /etc/systemd/system/update-scion.timer ]; then
    sudo systemctl enable update-scion.timer
    sudo systemctl start update-scion.timer
fi
sudo systemctl start scion-daemon.service
sleep 2

echo "Verify SCION path availability"
enable_stun=0
if scion showpaths --no-probe $(echo $CONNECTION_TEST_TARGET | cut -d, -f1) > /dev/null; then
    echo "Verify SCION connection"
    if scion ping -c1 $CONNECTION_TEST_TARGET > /dev/null; then
        echo "All tests successful"
    else
        echo "Path are available, but ping test failed. If this is because there is a NAT between" \
        "your computer and the border router, it is necessary to enable the STUN NAT traversal" \
        "option in Scitra-TUN." | fold -s -w $WIDTH
        read -n1 -r -p "Enable STUN and NAT traversal in Scitra-TUN? (y/n) "; echo
        if [[ "$REPLY" == [yY] ]]; then enable_stun=1; fi
    fi
else
    echo "No paths available. Check the SCION daemon log with 'systemctl status scion-deamon'." \
    "If there are no errors this might be a temporary problem." | fold -s -w $WIDTH
    read -n1 -r -p "Proceed with setup? (y/n) "; echo && [[ "$REPLY" == [yY] ]] || exit 1
fi

#-------------------------------------------------------------------------------

echo -e "\n\033[1mStep 4: Configure Scitra-TUN\033[0m"
mapped_address=$(scion2ip $(scion address))
host_address=$(scion address | cut -d, -f2)
host_interface=$(ip -json address | jq -r --arg ip "$host_address" '.[]|select(.addr_info.[].local==$ip).ifname' | head -1)
echo "Host address: $host_address"
echo "Interface: $host_interface"
read -n1 -r -p "Is this correct (y/n) "; echo
if [[ ! "$REPLY" == [yY] ]]; then
    read -ep "Host address: " host_address
    read -ep "Interface: " host_interface
fi

echo "The TUN interface created by Scitra-TUN needs an IPv6 address. IPv6 applications" \
"using SCION must bind to this address. The TUN interface address is not used outside" \
"of the local host and can be any valid IPv6 address that isn't used otherwise." \
"The default for IPv4 underlays is to use SCION-mapped IPv6 address of the host." \
"For IPv6 underlays you should pick a different address (typically ::2 or fd00::1)." \
| fold -s -w $WIDTH
read -ep "Address of the scion TUN interface (leave empty to use $mapped_address): " bind_address
bind_address=${bind_address:-$mapped_address}

if [[ $host_address =~ ":" ]]; then
    echo "Since your AS uses an IPv6 underlay, additional source routing rules are required" \
    "for AS-local traffic to be routed correctly. See man scitra-tun for more details." \
    "Please set up /usr/share/scitra-tun/config-routes according to your network configuration." \
    | fold -s -w $WIDTH
    read -n1 -r -p "Edit /usr/share/scitra-tun/config-routes now? (y/n) "; echo
    if [[ "$REPLY" == [yY] ]]; then
        sudo ${EDITOR:-/usr/bin/rnano} /usr/share/scitra-tun/config-routes
    fi
fi

if [[ $enable_stun -eq 0 ]]; then
    read -n1 -r -p "Enable STUN and NAT traversal in Scitra-TUN? (y/n) "; echo
    if [[ "$REPLY" == [yY] ]]; then enable_stun=1; fi
fi
if [[ $enable_stun -eq 1 ]]; then
    echo "Scitra-TUN can multiplex STUN requests on the same ports as used for regular" \
    "SCION packets. Alternatively, STUN servers are expected at a different fixed port." \
    "If your AS supports multiplexed STUN, answer the next question with 0 otherwise" \
    "enter the STUN port." | fold -s -w $WIDTH
    read -ep "Please enter the STUN port (leave empty to use 3478): " stun_port
    stun_port=${stun_port:-3478}
fi

sed "/^interface/c\interface = $host_interface" /etc/scion/scitra-tun.conf \
| sed "/^address/c\address = $host_address" \
| sed "/^[# ]*tun-addr/c\tun-addr = $bind_address" \
| sed "/^[# ]*scmp/c\scmp = 1" \
| sed "/^[# ]*stun =/c\stun = $enable_stun" \
| sed "/^[# ]*stun-port/c\stun-port = $stun_port" \
| sudo sponge /etc/scion/scitra-tun.conf

echo "Add localhost.scion to /etc/hosts"
(sed "/localhost.scion/d" /etc/hosts; echo "$mapped_address localhost.scion") | sudo sponge /etc/hosts
if [[ $wsl -eq 1 ]]; then
    echo "For WSL2 users: Consider adding"
    echo "[network]"
    echo "generateHosts = false"
    echo "to /etc/wsl.conf to prevent the hosts file from being overwritten by WSL."
fi

echo "Enable and start Scitra-TUN"
sudo systemctl enable scitra-tun.service
sudo systemctl start scitra-tun.service
sleep 2

echo "Verify Translation"
ping -p ff -e 65535 -6 -c2 $(scion2ip $CONNECTION_TEST_TARGET) > /dev/null # preload path cache
if ping -p ff -e 65535 -6 -c1 $(scion2ip $CONNECTION_TEST_TARGET) > /dev/null; then
    echo "Success"
else
    echo "Translation test failed"
    read -n1 -r -p "Proceed anyway? (y/n) "; echo && [[ "$REPLY" == [yY] ]] || exit 1
fi

#-------------------------------------------------------------------------------

echo -e "\n\033[1mStep 5: (Optional) Configure SCION DNS\033[0m"
enable_dns=0
if systemctl status systemd-resolved.service > /dev/null; then
    echo "In order to resolve SCION DNS TXT entries to IPv6 addresses for Scitra-TUN" \
    "you need a suitable DNS server. This script can set up $SCION_DNS_SERVER as resolver" \
    "for domains scion, scion.host and scion.fast. If you want a different configuration" \
    "consider editing /usr/share/scitra-tun/config-dns manually." | fold -s -w $WIDTH
    resolv_mode=$(resolvectl status | sed -rn 's/[[:space:]]*resolv.conf mode:[[:space:]]*(.*)/\1/p')
    if [[ $resolv_mode == "foreign" ]]; then
        echo "WARNING: Detected a resolv.conf mode of '$resolv_mode'. The SCION DNS configured by" \
        "this script will likely not work." | fold -s -w $WIDTH
        if [[ $wsl -eq 1 ]]; then
            echo "For WSL2 users: This can be fixed by adding"
            echo "[network]"
            echo "generateResolvConf = false"
            echo "to /etc/wsl.conf and rebooting."
        fi
    fi
    read -n1 -r -p "Configure SCION DNS (y/n) "; echo
    if [[ "$REPLY" == [yY] ]]; then
        enable_dns=1
    fi
else
    echo "Skipping DNS configuration, because the system is not using systemd-resolved." \
    "Consider editing /usr/share/scitra-tun/config-dns manually." | fold -s -w $WIDTH
fi

sed "/^ENABLE/c\ENABLE=$enable_dns" /usr/share/scitra-tun/config-dns \
| sed "/^SCION_DNS_SERVER/c\SCION_DNS_SERVER=$(scion2ip $SCION_DNS_SERVER)" \
| sed "/^DNS_DOMAIN/c\DNS_DOMAIN=\"~scion ~scion.host ~scion.fast\"" \
| sudo sponge /usr/share/scitra-tun/config-dns

if [[ $enable_dns -eq 1 ]]; then
    sudo systemctl restart scitra-tun
    sleep 1
    sudo resolvectl flush-caches
    echo "Verify DNS-over-SCION"
    ping -p ff -e 65535 -6 -c2 $DNS_TEST_TARGET > /dev/null # preload path cache
    if ping -p ff -e 65535 -6 -c1 $DNS_TEST_TARGET > /dev/null; then
        echo "Success"
    else
        echo "DNS test failed"
        exit 1
    fi
fi

#-------------------------------------------------------------------------------

echo -e "\n\033[1mSetup complete\033[0m"
if [[ $enable_dns -eq 1 ]]; then
    read -n1 -r -p "Open https://welcome.scion.host in a browser? (y/n) "; echo
    if [[ "$REPLY" == [yY] ]]; then
        xdg-open https://welcome.scion.host
    fi
fi

exit 0
