#!/bin/bash

echo "Starting docker machine..."

trap '[ "$?" -eq 0 ] || read -p "Looks like something went wrong in step ´$STEP´... Press any key to continue..."' EXIT

#Quick Hack: used to convert e.g. "C:\Program Files\Docker Toolbox" to "/c/Program Files/Docker Toolbox"
win_to_unix_path(){ 
	wd="$(pwd)"
	cd "$1"
		the_path="$(pwd)"
	cd "$wd"
	echo $the_path
}

# This is needed  to ensure that binaries provided
# by Docker Toolbox over-ride binaries provided by
# Docker for Windows when launching using the Quickstart.
export PATH="$(win_to_unix_path "${DOCKER_TOOLBOX_INSTALL_PATH}"):$PATH"
VM=${DOCKER_MACHINE_NAME-default}
DOCKER_MACHINE="${DOCKER_TOOLBOX_INSTALL_PATH}\docker-machine.exe"

# STEP="Looking for vboxmanage.exe"
# if [ ! -z "$VBOX_MSI_INSTALL_PATH" ]; then
#   VBOXMANAGE="${VBOX_MSI_INSTALL_PATH}VBoxManage.exe"
# else
#   VBOXMANAGE="${VBOX_INSTALL_PATH}VBoxManage.exe"
# fi

BLUE='\033[1;34m'
GREEN='\033[0;32m'
NC='\033[0m'

#clear all_proxy if not socks address
if  [[ $ALL_PROXY != socks* ]]; then
  unset ALL_PROXY
fi
if  [[ $all_proxy != socks* ]]; then
  unset all_proxy
fi

if [ ! -f "${DOCKER_MACHINE}" ]; then
  echo "Docker Machine is not installed. Please re-run the Toolbox Installer and try again."
  exit 1
fi

# if [ ! -f "${VBOXMANAGE}" ]; then
#   echo "VirtualBox is not installed. Please re-run the Toolbox Installer and try again."
#   exit 1
# fi

# "${VBOXMANAGE}" list vms | grep \""${VM}"\" &> /dev/null
powershell -NoProfile -Command "Get-WmiObject Win32_Process -Filter \"name = 'qemu-system-x86_64.exe'\" | Select-Object CommandLine | select-String '${VM}'" &> /dev/null
VM_EXISTS_CODE=$?

set -e

STEP="Checking if machine $VM exists"
if [ $VM_EXISTS_CODE -eq 1 ]; then
  "${DOCKER_MACHINE}" rm -f "${VM}" &> /dev/null || :
  rm -rf ~/.docker/machine/machines/"${VM}"
  #set proxy variables inside virtual docker machine if they exist in host environment
  if [ "${HTTP_PROXY}" ]; then
    PROXY_ENV="$PROXY_ENV --engine-env HTTP_PROXY=$HTTP_PROXY"
  fi
  if [ "${HTTPS_PROXY}" ]; then
    PROXY_ENV="$PROXY_ENV --engine-env HTTPS_PROXY=$HTTPS_PROXY"
  fi
  if [ "${NO_PROXY}" ]; then
    PROXY_ENV="$PROXY_ENV --engine-env NO_PROXY=$NO_PROXY"
  fi
  # "${DOCKER_MACHINE}" create -d virtualbox $PROXY_ENV "${VM}"
  "${DOCKER_MACHINE}" create -d qemu $PROXY_ENV "${VM}"
fi

STEP="Checking status on $VM"
VM_STATUS="$( set +e ; "${DOCKER_MACHINE}" status "${VM}" )"
if [ "${VM_STATUS}" != "Running" ]; then
  "${DOCKER_MACHINE}" start "${VM}"
  yes | "${DOCKER_MACHINE}" regenerate-certs "${VM}"
fi

STEP="Setting env"
eval "$("${DOCKER_MACHINE}" env --shell=bash --no-proxy "${VM}" | sed -e "s/export/SETX/g" | sed -e "s/=/ /g")" &> /dev/null #for persistent Environment Variables, available in next sessions
eval "$("${DOCKER_MACHINE}" env --shell=bash --no-proxy "${VM}")" #for transient Environment Variables, available in current session

STEP="Setting Shared beetween HOST and VM"
PROCESS_USE_PORT_1445=$(powershell -NoProfile -Command "Get-NetTCPConnection | where Localport -eq 1445")
if [[ -n "$PROCESS_USE_PORT_1445" ]]; then
  PROCESS_USE_PORT_1445=$(powershell -NoProfile -Command "Get-Process -Id (Get-NetTCPConnection -LocalPort 1445).OwningProcess | Select -ExpandProperty Id")
fi

if [[ -z "$PROCESS_USE_PORT_1445" ]]; then
  JLAN_LOG=$HOME/.docker/machine/machines/${VM}/jlan.log
  # JLAN_LOG=$(powershell -NoProfile -Command "echo \$HOME")
  # JLAN_LOG="${JLAN_LOG}\.docker\machine\machines\\${VM}\jlan.log"
  # powershell -NoProfile -Command "Set-Location -Path \"${DOCKER_TOOLBOX_INSTALL_PATH}\"; java -D\"java.library.path\"=./alfresco-jlan/jni -cp \"./alfresco-jlan/jars/alfresco-jlan.jar;./alfresco-jlan/libs/cryptix-jce-provider.jar;./alfresco-jlan/wrapper/wrapper.jar\" org.alfresco.jlan.app.JLANServer \"./alfresco-jlan/jlanConfig.xml\" | Out-File ${JLAN_LOG}" &
  (java -Djava.library.path="./alfresco-jlan/jni" -cp "./alfresco-jlan/jars/alfresco-jlan.jar;./alfresco-jlan/libs/cryptix-jce-provider.jar;./alfresco-jlan/wrapper/wrapper.jar" org.alfresco.jlan.app.JLANServer "./alfresco-jlan/jlanConfig.xml") & #> ${JLAN_LOG} &
  sleep 5s
  # tail -n 10 ${JLAN_LOG}
else
  IS_JLAN_RUNNING=$(powershell -NoProfile -Command "Get-WmiObject Win32_Process -Filter \"ProcessId = ${PROCESS_USE_PORT_1445}\" | Select-Object CommandLine | Select-String 'java.exe' | Select-String 'jlan'")
  if [[ -z "$IS_JLAN_RUNNING" ]]; then
    echo "Port 1445 is being used by other process, Cannot start JLAN server!"
    echo "Run command \"Get-NetTCPConnection | where Localport -eq 1445\" in PowerShell to see detail."
    exit 1
  else
    echo "JLAN server is running"
  fi
fi

echo "Mounting HOST Shared folder in VM..."
VM_ARGS=$(powershell -NoProfile -Command "Get-WmiObject Win32_Process -Filter \"name = 'qemu-system-x86_64.exe'\" | Select-Object CommandLine | select-String '${VM}'")
SSH_FW=$(echo $VM_ARGS | grep -oP "_*hostfwd=tcp:127.0.0.1:\d*-:22_*")
SSH_PORT=$(echo ${SSH_FW:22:5})

if yes | plink -ssh docker@localhost -P ${SSH_PORT} -pw tcuser "mount | grep /mnt/workspaces"; then
  :
else
  HOST_IP=$(powershell -NoProfile -Command "(Test-Connection -ComputerName (hostname) -Count 1  | Select -ExpandProperty IPV4Address).IPAddressToString")

  yes | pscp -r -pw tcuser -P ${SSH_PORT} "${DOCKER_TOOLBOX_INSTALL_PATH}\\tcz\\*" docker@localhost:
  yes | plink -ssh docker@localhost -P ${SSH_PORT} -pw tcuser "tce-load -i mtd-4.19.10-tinycore64.tcz filesystems-4.19.10-tinycore64.tcz libcups2.tcz popt.tcz samba-libs.tcz cifs-utils.tcz \
    && sudo mkdir -p /mnt/workspaces \
    && sudo mount -v -t cifs //${HOST_IP}/WORKSPACES /mnt/workspaces -o username=sdv,password=samsung@1,port=1445,vers=1.0"
fi

STEP="Finalize"
clear
cat << EOF


                        ##         .
                  ## ## ##        ==
               ## ## ## ## ##    ===
           /"""""""""""""""""\___/ ===
      ~~~ {~~ ~~~~ ~~~ ~~~~ ~~~ ~ /  ===- ~~~
           \______ o           __/
             \    \         __/
              \____\_______/

EOF
echo -e "${BLUE}docker${NC} is configured to use the ${GREEN}${VM}${NC} machine with IP ${GREEN}$("${DOCKER_MACHINE}" ip ${VM})${NC}"
echo "For help getting started, check out the docs at https://docs.docker.com"
echo
echo 
#cd #Bad: working dir should be whatever directory was invoked from rather than fixed to the Home folder

docker () {
  MSYS_NO_PATHCONV=1 docker.exe "$@"
}
export -f docker

if [ $# -eq 0 ]; then
  echo "Start interactive shell"
  exec "$BASH" --login -i
  exec "$BASH" --login -i
else
  echo "Start shell with command"
  exec "$BASH" -c "$*"
fi
