#!/bin/bash -e
version="1.0.1"

AZIOT_VERSION="1.4.2"
AZIOT_IDENTITY_VERSION="1.4.1"

usage() {
	cat <<EOF >&2
Usage $0 <options> onboard|offboard

Options:
  -a, --apikey   <apikey>   : authentication method A: equals to an API key with correct authorization permissions received from cloud instance
  -u, --username <username> : alternative authentication method B, part 1: equals a username (typically named account) with correct authorization permissions
  -p, --password <password> : alternative authentication method B, part 2: equals the password of the given user/username (account)
  -i, --instance <instance> : represents the cloud back-end instance URL the script shall link the device to. Defaults to netfield.io if not specified
  -m, --manifest: lets the cloud back-end automatically execute the cloud deposited device manifest after device onboarding
  -v, --verbose : outputs detailed information for debugging purposes about the script's activities during execution
  -h, --help    : Shows this help message
EOF
	exit 1
}

print_verbose() {
	if [ "$verbose" = "1" ]; then
		if [ -n "$password" ]; then
			# shellcheck disable=SC2001
			echo "${1//\"$password\"/\"****\"}" | sed -e 's;\("accessToken"[ ]*:[ ]*\)".*";\1"*****";gi'
		else
			# shellcheck disable=SC2001
			echo "$1" | sed -e 's;\("accessToken"[ ]*:[ ]*\)".*";\1"*****";gi'
		fi
	fi
}

setup_second_docker_instance() {
	if systemctl is-active --quiet iotedge-docker; then
		# Already setup, so skip this step
		print_verbose "docker/moby: Already found second instance, skipping setup"
		return
	fi

	print_verbose "moby/docker: Setting up second docker/moby instance"

	if [ ! -e "/etc/default/iotedge" ]; then
		mkdir -p /etc/default
		echo 'BRIDGE_IP="10.252.253.1/24"' > /etc/default/iotedge
	fi

	mkdir -p /etc/default
	dockerip=$(ip addr show dev docker0 2>/dev/null | grep -Eo "inet [0-9./]+" | cut -d ' ' -f2)
	[ -z "$dockerip" ] && dockerip=$(ip addr show dev usrdocker0 2>/dev/null | grep -Eo "inet [0-9./]+" | cut -d ' ' -f2)
	[ -z "$dockerip" ] && dockerip="172.17.0.1/16"
	echo "BRIDGE_IP=\"${dockerip}\"" >> /etc/default/docker

	if [ ! -e "/etc/docker/daemon.json" ]; then
		mkdir -p /etc/docker
		echo "{}" > /etc/docker/daemon.json
	fi

	daemonjson=$(jq '.bridge="usrdocker0"' < /etc/docker/daemon.json | jq '.')
	echo "$daemonjson" > /etc/docker/daemon.json

	mkdir -p /etc/systemd/system/docker.service.d

	cat <<EOF> /etc/systemd/system/docker.service.d/userbridge.conf
[Service]
###############################
# Create / remove custom bridge
###############################
Environment=BRIDGE_IP=172.17.0.1/16
EnvironmentFile=-/etc/default/docker

ExecStartPre=$(command -v brctl) addbr usrdocker0
ExecStartPre=$(command -v ip) addr add \${BRIDGE_IP} dev usrdocker0
ExecStartPre=$(command -v sysctl) net.ipv6.conf.usrdocker0.disable_ipv6=1
ExecStartPre=$(command -v ip) link set dev usrdocker0 up
ExecStopPost=$(command -v ip) link set dev usrdocker0 down
ExecStopPost=$(command -v brctl) delbr usrdocker0
###############################
EOF

	bridge_commands="\n\
###############################\n\
# Create / remove custom bridge\n\
###############################\n\
Environment=BRIDGE_IP=10.252.253.1/24\n\
EnvironmentFile=-/etc/default/iotedge\n\
\n\
ExecStartPre=$(command -v brctl) addbr iotedge0\n\
ExecStartPre=$(command -v ip) addr add \${BRIDGE_IP} dev iotedge0\n\
ExecStartPre=$(command -v sysctl) net.ipv6.conf.iotedge0.disable_ipv6=1\n\
ExecStartPre=$(command -v ip) link set dev iotedge0 up\n\
ExecStopPost=$(command -v ip) link set dev iotedge0 down\n\
ExecStopPost=$(command -v brctl) delbr iotedge0\n\
###############################\n"


	# Use distro version of docker services and patch our special settings
	sed -e 's@^Description=.*@& (netFIELD.io instance)@' \
	    -e 's@/bin/dockerd@& --config-file /etc/docker/iotedge.json@' \
	    -e 's@docker.socket@iotedge-docker.socket@g' \
	    -e "s@^\[Service\].*@& $bridge_commands@" \
	    -e '/^After=.*/a PartOf=docker.service' \
	    "$systemd_dir"/docker.service > /etc/systemd/system/iotedge-docker.service


	chmod 0644 /etc/systemd/system/iotedge-docker.service

	sed -e 's@^Description=.*@& (netFIELD.io instance)@' \
	    -e 's@docker.service@iotedge-docker.service@g' \
	    -e 's@docker.sock@iotedge-docker.sock@g' \
	    -e 's@/var/run/@/run/@g' \
	    "$systemd_dir"/docker.socket > /etc/systemd/system/iotedge-docker.socket

	chmod 0644 /etc/systemd/system/iotedge-docker.socket

	mkdir -p /etc/docker
cat << EOF > /etc/docker/iotedge.json
{
  "bridge"    : "iotedge0",
  "data-root" : "/var/lib/iotedge-docker",
  "pidfile"   : "/run/iotedge-docker.pid",
  "exec-root" : "/run/iotedge-docker",
  "default-address-pools": [
    {
      "base": "10.253.0.1/16",
      "size": 24
    }
  ]
}
EOF
	chmod 0640 /etc/docker/iotedge.json

	case "$ID" in
	ubuntu|debian)
		if [ -e "$systemd_dir/containerd.service" ]; then
			# Debian / Ubuntu use a separate containerd instance, thus we need to duplicate it
			mkdir -p /etc/containerd/
			cat <<EOF> /etc/containerd/iotedge-config.toml
disabled_plugins = ["cri"]
root = "/var/lib/iotedge-containerd"
state = "/run/iotedge-containerd"
[grpc]
  address = "/run/iotedge-containerd/containerd.sock"
  uid = 0
  gid = 0

#[debug]
#  address = "/run/iotedge-containerd/debug.sock"
#  uid = 0
#  gid = 0
#  level = "info"
EOF
			cp "$systemd_dir"/containerd.service /etc/systemd/system/iotedge-containerd.service
			sed -i -e 's@\(^ExecStart=.*\)@\1 --config /etc/containerd/iotedge-config.toml@g' \
			    -e '/^After=.*/a PartOf=containerd.service' \
			    /etc/systemd/system/iotedge-containerd.service
			sed -i -e 's@/run/containerd/containerd.sock@/run/iotedge-containerd/containerd.sock@g' \
			    -e 's@containerd.service@iotedge-containerd.service@g' \
			    /etc/systemd/system/iotedge-docker.service
			additional_services="iotedge-containerd.service"
		fi
		;;
	esac

	sync
	systemctl daemon-reload
	sleep 2
	print_verbose "docker/moby: Starting second docker instance"
	systemctl stop $additional_services docker iotedge-docker
	systemctl start --no-block $additional_services docker iotedge-docker
	systemctl enable $additional_services docker iotedge-docker.socket
}

# shellcheck disable=SC2120
install_prerequisites() {

	case "$ID-$VERSION_ID" in
	ubuntu-18.04|ubuntu-20.04|debian-10|debian-11|raspbian-10|raspbian-11)

		print_verbose "Detected deb/apt based system"

		OLDPATH="$PATH"
		export PATH="$PATH:/usr/sbin:/sbin"

		case "$(dpkg --print-architecture)" in
		amd64|armhf|arm64) : ;;
		*)
			echo "!!! Only amd64, armhf or arm64 platforms are supported on debian based systems"
			exit 1
			;;
                esac

		if ! dpkg-query -l apt-transport-https > /dev/null 2>&1; then
			print_verbose "apt-transport-https not found: Installing apt-transport-https and ca-certificates"
			direct_dependencies="$direct_dependencies apt-transport-https ca-certificates"
		fi

		if ! command -v curl >/dev/null; then
			print_verbose "curl not found: Installing curl"
			direct_dependencies="$direct_dependencies curl"
		fi

		if ! command -v gpg >/dev/null; then
			print_verbose "gpg not found: Installing gpg"
			direct_dependencies="$direct_dependencies gpg"
		fi

		if [ -n "$direct_dependencies" ]; then
			apt-get update
			# shellcheck disable=SC2086
			apt-get install -y $direct_dependencies
		fi

		if ! command -v openssl >/dev/null; then
			print_verbose "openssl not found: Installing openssl"
			packages_to_install="$packages_to_install openssl"
		fi


		if ! command -v brctl >/dev/null; then
			print_verbose "brctl not found: Installing bridge-utils"
			packages_to_install="$packages_to_install bridge-utils"
		fi

		if ! command -v jq >/dev/null; then
			print_verbose "jq not found: Installing jq"
			packages_to_install="$packages_to_install jq"
		fi

		if ! command -v docker >/dev/null; then
			print_verbose "docker not found: Installing moby"

			# Convert distributor id to lowercase, e.g. "Debian" => "debian"
			lower_id=$(echo $ID | tr '[:upper:]' '[:lower:]')

			sudo mkdir -p /etc/apt/keyrings
			curl -fsSL https://download.docker.com/linux/$lower_id/gpg  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
			chmod a+r /etc/apt/keyrings/docker.gpg

			echo \
				"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$lower_id $(lsb_release -cs) stable" \
				| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

			packages_to_install="$packages_to_install docker-ce docker-ce-cli containerd.io docker-compose-plugin"
		fi

		if [ -n "$packages_to_install" ]; then
			apt-get update
			# shellcheck disable=SC2086
			apt-get install -y $packages_to_install
		fi

		# Prepare 2nd docker instance
		setup_second_docker_instance

		if ! command -v iotedge >/dev/null; then
			
			tmpdir=$(mktemp -d)
			cd "$tmpdir"

			os_version_arch="${ID}${VERSION_ID}_$(dpkg --print-architecture)"
			
			# aziot-edge depends on aziot-identity-service, which should be installed first.
			packages="aziot-identity-service_${AZIOT_IDENTITY_VERSION}-1_${os_version_arch}.deb \
				  aziot-edge_${AZIOT_VERSION}-1_${os_version_arch}.deb"

			apt-get update

			for package in $packages; do
				curl -s -L https://github.com/Azure/azure-iotedge/releases/download/"${AZIOT_VERSION}"/"$package" > "$package"
				apt-get install -y "$tmpdir/$package"
			done

			cd -
			rm -rf "$tmpdir"

			# Fix wrong user permission after installation
			usermod -a -Gaziotcs,aziotks,aziotid,aziottpm iotedge
		fi

		export PATH="$OLDPATH"

		;;
	*)
		echo "Unsupported linux distribution $ID-$VERSION_ID"
		exit 1
		;;
	esac

	# Detect iotedge version
	iotedgeversion=$(iotedge version | cut -d ' ' -f 2 | grep -o '^1.[01234]')
	print_verbose "iotedge: Detected version $iotedgeversion"
	case "$iotedgeversion" in
		1.[01])
			# Patch docker socket of 2nd docker instance into configuation
			sed -i.bak -e "s@\([ ]\)+uri: .*@\1uri: \"unix:///run/iotedge-docker.sock\"@g" \
				   -e "s@^hostname:@hostname: \"$(hostname)\"@g" \
				   /etc/iotedge/config.yaml
			;;
		1.[234])
			# Patch docker socket of 2nd docker instance into configuation
			sed -i.bak -e "s@^uri =.*@uri = \"unix:///run/iotedge-docker.sock\"@g" /etc/aziot/edged/config.toml.default
			sed -i.bak -e "s@^uri =.*@uri = \"unix:///run/iotedge-docker.sock\"@g" /etc/aziot/config.toml.edge.template
			;;
		*)
			echo "Unsupported iotedge version $(iotedge version)"
			;;
	esac
	cat <<EOF> /usr/bin/docker-iotedge
#!/bin/sh

if [ ! -e "/run/iotedge-docker.sock" ]; then
        echo "IoT-Edge instance of docker not found."
        echo "Make sure on-boarding succeeded and service has been started."
        exit 1
fi

docker -H unix:///run/iotedge-docker.sock "\$@"
EOF
	chmod +x /usr/bin/docker-iotedge
}

decode_base64_url() {
	local len=$((${#1} % 4))
	local result="$1"
	if [ $len -eq 2 ]; then result="$1"'=='
	elif [ $len -eq 3 ]; then result="$1"'='
	fi
	echo "$result" | tr '_-' '/+' | openssl enc -d -base64
}

decode_jwt(){
	# shellcheck disable=SC2046
	decode_base64_url $(echo -n "$2" | cut -d "." -f "$1")
}

execute_cloud_command() {
	local request="$1"
	local url="$2"
	local add_header="$3"
	local data="$4"
	# If error_message is empty, we expect the caller to evaluate results
	local error_message="$5"

	print_verbose " -> $url [$request, $(echo "$data" | jq -c .)]"

	set +e
	response=$(curl -s --show-error -X "$request" "$url" \
			     -H "$add_header" \
			     -H 'Content-Type: application/json' \
			     -d "$data" 2>&1)
	local error=$?
	set -e

	if [ $error -ne 0 ]; then
		if [ -n "$error_message" ]; then
			echo "$error_message"
			echo " curl returned $response"
			exit 1
		fi
	fi

	print_verbose " <- $url $response"

	local message
	message=$(echo "$response" | jq -r '.message')
	if [ -n "$message" ] && [ "$message" != "null" ]; then
		if [ -n "$error_message" ]; then
			echo "$error_message"
			echo " Message: $message"
			exit 1
		fi
	fi
}

get_netfield_arch() {
	case "$(uname -m)" in
	i[3-6]86) echo "X86" ;;
	x86_64) echo "X64" ;;
	armv7*) echo "ARM32V7" ;;
	aarch64) echo "ARM64V8" ;;
	*) echo "unkown arch $(uname-m)" ;;
	esac
}

create_device() {
	accesstoken="$1"
	organisation_id=$(decode_jwt 2 "$accesstoken" | jq '.oId')

	execute_cloud_command "POST" "$apiinstance/v1/devices" \
		"Authorization: $accesstoken" \
		"{ \
			\"onboardingType\": \"manual\", \
			\"organisationId\": $organisation_id, \
			\"deviceType\": \"standard\", \
			\"name\": \"$(hostname)\", \
			\"firmwareVersion\": \"${VERSION}\", \
			\"modelName\": \"${NAME}-$(uname -m)\", \
			\"upstreamProtocol\": \"${upstream_proto}\", \
			\"processorArchitecture\" : \"$(get_netfield_arch)\" \
		 } \
		" \
		"Error creating device"
	new_device=$response
}

get_access_token_from_workspace() {
  local wsId="${1}"
  local wsName="${2}"
  local wsToken="${3}"

  echo "Loggin into $wsName workspace"

  execute_cloud_command "POST" "$apiinstance/v1/auth" "" \
    "{
        \"grantType\":\"workspace\",
        \"workspaceId\":\"${wsId}\",
        \"workspaceToken\":\"${wsToken}\",
        \"stayLoggedIn\": false
    }" \
    "Error logging into workspace $workspaceName"

  accesstoken=$(echo "$response" | jq -r '.accessToken')
}

select_2FA_method() {
  local methods="${1}"

  # Let the user choose between available methods
  local TWO_FA_METHODS=()
  local methodNames=$(echo "$methods" | jq -r '.[]')
  local methodsCount=$(echo "$methods" | jq '. | length')

  for i in "${methodNames}"
  do
    local name=$(echo "$i" | jq -r '.type')
    TWO_FA_METHODS+=("$name")
  done

  PS3="Choose a two-factor auth type (Available: $methodsCount): "
  select METHOD in $TWO_FA_METHODS
  do
    if [ -n "$METHOD" ]
    then
      echo "Selected two-factor auth method: ${METHOD}"
      selectedWorkspace=$(($REPLY - 1))
      break
    else
      echo "Invalid input!"
    fi
  done
  SELECTED_METHOD=$(echo "$methods" | jq .[$selectedWorkspace])
}

login_workspaces() {
  local wsToken="${1}"
  local workspaces="${2}"
  local workspacesLength=$(echo "$workspaces" | jq '. | length')
  
  if [ $workspacesLength -eq 1 ]
  then
    # If only one workspace - get access token
    local workspaceId=$(echo "$workspaces" | jq '.[0].id')
    local workspaceName=$(echo "$workspaces" | jq '.[0].name')

    get_access_token_from_workspace "$workspaceId" "$workspaceName" "$wsToken"
  else
    # Let the user choose between workspaces and get access token
    local WORKSPACES=()
    local selectedWorkspace
    local workspaceNames=$(echo "$workspaces" | jq -r '.[]')
    for i in "${workspaceNames}"
    do
      local name=$(echo "$i" | jq -r '.name')
      local nameWithUnderscore=$(echo "$name" | sed -e 's/ /_/g')
      WORKSPACES+=("$nameWithUnderscore")
    done

    PS3="Choose a workspace to login (Available: $workspacesLength): "
    select WS in $WORKSPACES
    do
      if [ -n "$WS" ]
      then
        echo "Selected workspace: ${WS}"
        selectedWorkspace=$(($REPLY - 1))
        break
      else
        echo "Invalid input!"
      fi
    done

    local selectedWorkspaceId=$(echo "$workspaces" | jq .[$selectedWorkspace].id)
    local selectedWorkspaceName=$(echo "$workspaces" | jq .[$selectedWorkspace].name)

    get_access_token_from_workspace "$selectedWorkspaceId" "$selectedWorkspaceName" "$wsToken"
  fi
}

login_two_factor_auth() {
  local accessTokenTwoFA="${1}"
  local authMethods

  # Get 2FA available Methods
  execute_cloud_command "GET" "$apiinstance/v1/auth/two-factor" \
		"Authorization: $accessTokenTwoFA" \
		"" \
		"Error getting two-factor authentication methods"

  authMethods=$(echo "$response" | jq -r '.methods')
  select_2FA_method "$authMethods"

  local methodID=$(echo "$SELECTED_METHOD" | jq -r '.id')

  execute_cloud_command "POST" "$apiinstance/v1/auth/two-factor" \
		"Authorization: $accessTokenTwoFA" \
    "{
      \"twoFactorId\":\"${methodID}\"
    }" \
		"Error selecting two-factor authentication"
  

  # Let the user write the auth code
  local authCode
  read -p "Enter authentication code: " authCode
  # checks if value is empty and if there are whitespaces
  while [[ -z "$authCode" || "$authCode" =~ \ |\' ]]
  do
    read -p "Please enter valid authentication code: " authCode
  done

  # Verify two-factor authentication code and generate authorization and refresh token or workspace token
  execute_cloud_command "POST" "$apiinstance/v1/auth/two-factor/methods/$methodID" \
		"Authorization: $accessTokenTwoFA" \
    "{
      \"code\":\"${authCode}\",
      \"tokenType\":\"workspaceToken\"
    }" \
		"Error Verify two-factor authentication code"

  local wsToken=$(echo "$response" | jq -r '.workspaceToken')
  local workspaces=$(echo "$response" | jq -r '.workspaces')

  login_workspaces "$wsToken" "$workspaces"
}

login() {
  local wsToken
  local workspaces
  local aToken

  execute_cloud_command "POST" "$apiinstance/v1/auth/workspaces" "" \
    "{
      \"grantType\":\"password\",
      \"email\":\"${username}\",
      \"password\":\"${password}\"
    }" \
    "Error logging into account $username"

  aToken=$(echo "$response" | jq -r '.accessToken')

  if [ "$aToken" == null ]
  then
    # Login using workspace token
    wsToken=$(echo "$response" | jq -r '.workspaceToken')
    workspaces=$(echo "$response" | jq -r '.workspaces')

    login_workspaces "$wsToken" "$workspaces"
  else
    # Login with two-factor authentication
    login_two_factor_auth "$aToken"
  fi
}

login_cloud() {
  if [ -n "$apikey" ]; then
    # Use API Key
    accesstoken="$apikey"
  else
    # Generate access token
    login
  fi
}

version_lte() {
	[  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

version_lt() {
	if [ "$1" = "$2" ]; then
		return 1
	else
		version_lte "$1" "$2"
	fi
}

onboard_device() {
	if [ -e "/etc/netfield.io" ]; then
		echo "Onboarding transaction file /etc/netfield.io found. Device seems be onboarded already, please offboard it first"
		exit 1
	fi

	login_cloud

	execute_cloud_command "GET" "$apiinstance/v1/info" \
		"Authorization: $accesstoken" \
		"" \
		"Error querying cloud version. This script requires at least netFIELD cloud V3.1.0"
	cloud_version=$(echo "$response" | jq -r '.version')
	cloud_major=$(echo "$cloud_version" | grep -Eo "[[:digit:]]+.[[:digit:]]+")
	if version_lt "$cloud_major" "3.1"; then
		echo "Unsupported cloud version '$cloud_version' on $apiinstance"
		echo "Onboarding a custom device requires at least netFIELD cloud V3.1.0"
		exit 1
	fi

	print_verbose "Detected Cloud version '$cloud_version' on '$apiinstance'"

	create_device "$accesstoken"

	activation_code=$(echo "$new_device" | jq -r '.activationCode')
	serial_number=$(echo "$new_device" | jq -r '.serialNumber')
	firmware_version=$(echo "$new_device" | jq -r '.firmwareVersion')
	model_name=$(echo "$new_device" | jq -r '.modelName')

	execute_cloud_command "POST" "$apiinstance/v1/devices/onboard/sas" \
		"Authorization: $accesstoken" \
		"{ \
			\"activationCode\": \"$activation_code\", \
			\"serialNumber\": \"$serial_number\", \
			\"firmwareVersion\": \"$firmware_version\", \
			\"modelName\": \"$model_name\", \
			\"useManifest\": $manifest \
		 } \
		" \
		"Error registering device"

	deviceid=$(echo "$response" | jq -r '.deviceId')
	connectionstring=$(echo "$response" | jq -r '.connectionString')

	print_verbose "iotedge: Starting connection to netFIELD.io cloud"
	case "$iotedgeversion" in
        1.[01])
		sed -i.bak "s@device_connection_string:.*@device_connection_string: \"$connectionstring\"@g" /etc/iotedge/config.yaml
		systemctl enable --now iotedged
		;;
	1.[234])
		sed -i -e "s@^[# ]*hostname =@hostname = \"$(hostname)\"@g" /etc/aziot/edged/config.toml.default
		iotedge config mp --connection-string "$connectionstring"
		iotedge config apply
		sed -i.bak -e "s@^uri =.*@uri = \"unix:///run/iotedge-docker.sock\"@g" /etc/aziot/config.toml
		iotedge config apply
		systemctl enable aziot-edged
		;;
	esac

	cat <<EOF>/etc/netfield.io
connectionstring="$connectionstring"
deviceid="$deviceid"
serial_number="$serial_number"
instance="$instance"
apiinstance="$apiinstance"
EOF

	# Create default gateway settings required by most netfield containers
	if [ ! -e "/etc/gateway/settings.json" ]; then
		mkdir -p /etc/gateway
		cat <<EOF>/etc/gateway/settings.json
{
  "schemaVersion": 1,
  "gatewayPrefix": "$serial_number",
  "remote-access": "off"
}
EOF
	fi

	# Create default mqtt configuration required by most netfield containers
	if [ ! -e "/etc/gateway/mqtt-config.json" ]; then
		mkdir -p /etc/gateway
		cat <<EOF>/etc/gateway/mqtt-config.json
{
  "schemaVersion": 1,
  "connectTimeout": 300,
  "serverURIs": ["tcp://localhost:1883", "tcp://mosquitto:1883"],
  "mqttVersion": 3
}
EOF
	fi

        # Define an alias for better usability
        alias docker-iotedge="docker -H unix:///run/iotedge-docker.sock"

        echo ""
        echo "#######################################################################################################"
        echo "  Device '${HOSTNAME}' has been successfully onboarded with the created"
        echo "  unique device id '${deviceid}' in the instance '${instance}'."
        echo "  Direct link: https://${instance}/apps/device/${deviceid}"
        echo ""
		echo "  These credentials have been stored under /etc/netfield.io. Please do not remove this file."
        echo "######################################################################################################"

}

offboard_device() {
	if [ ! -e "/etc/netfield.io" ]; then
		echo "!!! Device is not yet onboarded, please onboard it first"
		exit 1
	fi

	# Offboard from cloud
	login_cloud

	# shellcheck disable=SC1091
	. /etc/netfield.io

	# Check if device exists
	execute_cloud_command "GET" "$apiinstance/v1/devices/$deviceid" \
		"Authorization: $accesstoken" \
		"" \
		""

	local delete_device="1"

	local statuscode
	statuscode=$(echo "$response" | jq -r '.statusCode')
	if [ "$statuscode" = "null" ]; then
		print_verbose "Offboarding and deleting device with deviceid \"$deviceid\" from instance \"$instance\""
		print_verbose " Name:         $(echo "$response" | jq -r '.name')"
		print_verbose " Model:        $(echo "$response" | jq -r '.modelName')"
		print_verbose " SerialNumber: $(echo "$response" | jq -r '.serialNumber')"
		print_verbose " Organization: $(echo "$response" | jq -r '.organisationName')"
	elif [ "$statuscode" != "404" ]; then
		echo "Error querying device with deviceid \"$deviceid\""
		echo "  Status: $statuscode"
		echo "  Error:  $(echo "$response" | jq -r '.message')"
		exit 1
	else
		cat <<EOF
Device with deviceid "$deviceid" was not found on instance "$instance"!
If you already deleted it manually, you may continue the offboarding process by
entering "PROCEED"

EOF
		read -r -p "Enter PROCEED to forcefully continue offboarding: " confirmation
		if [ "$confirmation" != "PROCEED" ]; then
			echo "Aborting offboarding process!!"
			exit 1
		else
			delete_device="0"
		fi
	fi

	if [ "$delete_device" = "1" ]; then
		execute_cloud_command "PUT" "$apiinstance/v1/devices/offboard" \
			"Authorization: $accesstoken" \
			"{\"deviceId\": \"$deviceid\"}" \
			"Error offboarding device \"$deviceid\""

		execute_cloud_command "DELETE" "$apiinstance/v1/devices/${deviceid}" \
			"Authorization: $accesstoken" \
			"" \
			"Error deleting device \"$deviceid\""
	fi

	case "$iotedgeversion" in
	1.[01])
		systemctl disable --now iotedged
		;;
	1.[234])
		iotedge system stop
		systemctl disable aziot-edged
		;;
	esac

	rm /etc/netfield.io
	rm -f /etc/aziot/config.toml

	if systemctl is-enabled iotedge-containerd.service &> /dev/null; then
		additional_services="iotedge-containerd.service"
	fi

	systemctl disable --now iotedge-docker iotedge-docker.socket $additional_services

        echo ""
        echo "#################################################################################################"
        echo "  Device '${HOSTNAME}' with the device id '${deviceid}' has been successfully"
        echo "  offboarded from the instance '${instance}'."
        echo "#################################################################################################"
}

echo
echo "###############################################################################################"
echo "                         netFIELD Extension Linux Installer $version"
echo
echo "      Make sure this platform has an Internet connection during the script's execution"
echo
echo "      Copyright (c) Hilscher Gesellschaft fuer Systemautomation mbH. All rights reserved"
echo "Licensed under the LICENSE.txt file information stored in the project's source code repository "
echo "###############################################################################################"
echo

if [ -e /etc/os-release ]; then
   . /etc/os-release
else
   if [ -e /usr/lib/os-release ]; then
      . /usr/lib/os-release
   else
      echo "Can't detect Linux distribution. Script can't be executed"
      exit 1
   fi
fi

if [ -z "$ID" ] || [ "$ID" = "" ]; then
   echo "Can't detect Linux distribution. Script can't be executed"
   exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run this script as root!"
	exit 1
fi

if [ "$ID" = "raspbian" ]; then
   echo "Found Raspbian OS distribution, treating it as debian"
   ID="debian"
fi

instance="netfield.io"
upstream_proto="AMQPWS"
manifest="false"

while true; do
	case "$1" in
	-a|--apikey)   apikey=$2;   shift 2 ;;
	-u|--username) username=$2; shift 2 ;;
	-p|--password) password=$2; shift 2 ;;
	-i|--instance) instance=$2; shift 2 ;;
	-v|--verbose)  verbose="1";  shift   ;;
	-m|--manifest) manifest="true"; shift ;;
	-h|--help) usage ;;
	-*) usage ;;
	*) break ;;
    esac
done



if [ "$#" -ne 1 ] ; then
	usage
fi

if [ -z "$username" ] && [ -z "$apikey" ]; then
	echo "!!! Missing credentials for onboarding."
	echo "!!! Either provide username/password or API key"
	usage
fi

if [ -n "$username" ] && [ -z "$password" ]; then
	read -r -s -p "Enter password for $username on $instance : " password
	echo ""
fi

if [ -d "/usr/lib/systemd/system" ]; then
	systemd_dir="/usr/lib/systemd/system/"
else
	systemd_dir="/lib/systemd/system/"
fi

# shellcheck disable=SC2119
install_prerequisites

# extract the corresponding back-end URL (https://api...) from given instance info page
apiinstance=$(curl -s 'https://'"${instance}"'/info' | jq -r '.backendUrl')

case "$1" in
	onboard)  onboard_device ;;
	offboard) offboard_device ;;
	*)
		echo "Unknown option $1"
		usage
		;;
esac
