#!/bin/bash
LOG_FILE=$PWD"/docker.log" #Docker log file location
NETWORK="em1"  #Host DHCP Server interface
DOCKER_IMG_NAME="cxy4430/infrasim-compute" #Docker image name
DOCKER_IMG_TAG="latest" #Docker image tag
NAME="idic" #Container Name
PORT="5901" #Host port which is bind to container port

while getopts "h:i:t:p:n:" args;do
    case ${args} in
        i)
           NETWORK=$OPTARG
	   ;;
        t)
           DOCKER_IMG_TAG=$OPTARG
	   ;;
        p)
           PORT=$OPTARG
           ;;
        n)
           NAME=$OPTARG
           ;;
 	h)
           echo "$0 -n <Docker Instance Name> -i <host_dhcp_interface> -t <docker_image_tag> "
	   exit 1
           ;;
       *)
           echo "$0 -i <host_dhcp_interface> -t <docker_image_tag>"
	   exit 1
	   ;;
    esac
done	

log()
{
   echo -e ${PRX}"$(date "+%b %d %T") : $@" >> $LOG_FILE
}

log_and_exec()
{
   log "$@"
   eval "$@" 2>&1 |tee -a $LOG_FILE
   return ${PIPESTATUS[0]}  # otherwise, always return 1 as tee's exit code
}


# Prepare for docker environment
log_and_exec "rm $LOG_FILE"
log_and_exec "docker --version"
if [ $? -ne 0 ]; then
   log_and_exec "apt-get remove docker docker-engine"
   log_and_exec "apt-get update"
   log_and_exec "apt-get install -y apt-transport-https ca-certificates curl software-properties-common"
   log_and_exec "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -"
   log_and_exec "sudo apt-key fingerprint 0EBFCD88"
   log_and_exec "sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable""
   log_and_exec "apt-get update"
   log_and_exec "apt-get install -y docker-ce"
else
   echo "Docker already installed; Version: $(docker --version)"
fi

# Setup the host network
log_and_exec "apt-get install -y openvswitch-switch"
log_and_exec "ovs-vsctl add-br ovs-br0"
log_and_exec "ovs-vsctl add-port ovs-br0 $NETWORK"
log_and_exec "ip link set dev ovs-br0 up"
original_ip=$(ifconfig $NETWORK | awk '/inet addr/{print substr($2,6)}')
log_and_exec "ifconfig $NETWORK  0"
log_and_exec "ifconfig  ovs-br0 $original_ip"


# Setup docker container network
log_and_exec "docker images $DOCKER_IMG_NAME:$DOCKER_IMG_TAG"
log_and_exec "docker ps -a |grep -w $NAME"
if [ $? -ne 1 ]; then
   log_and_exec "docker stop $NAME"
   log_and_exec "docker rm $NAME"
fi
#log_and_exec "docker pull $DOCKER_IMG_NAME:$DOCKER_IMG_TAG"

# Clone pipework for network configuration
echo "Start Docker Image : $PORT:5901 --name $NAME $DOCKER_IMG_NAME:$DOCKER_IMG_TAG"
log_and_exec "docker run --privileged -p $PORT:5901 -dit --name $NAME $DOCKER_IMG_NAME:$DOCKER_IMG_TAG /bin/bash"
if [ $? -ne 0 ]; then
   echo "$DOCKER_IMG_NAME:$PORT start up failure. Exit.."
   exit -1
fi
if [ "$(which pipework)" == "" ]; then
  log_and_exec "git config --global http.sslverify false"
  log_and_exec "git clone https://github.com/jpetazzo/pipework.git"
  log_and_exec "scp $PWD/pipework/pipework /usr/local/bin/pipework"
  log_and_exec "chmod +x /usr/local/bin/pipework"
else
  echo "pipework is existing...."
fi
echo "Setting Up pipework network , connect eth1 of docker image $NAME with ovs-br0 ...."
log_and_exec "/bin/bash $PWD/pipework/pipework ovs-br0 -i eth1 $NAME dhclient"
echo "Setting Up Docker $NAME internal br0 ...."
log_and_exec "docker exec $NAME brctl addbr br0"
log_and_exec "docker exec $NAME brctl addif br0 eth1"


log_and_exec "IP=$(docker exec $NAME ifconfig eth1 | awk '/inet addr/{print substr($2,6)}')"
#IP=$(docker exec $NAME ifconfig eth1 | awk '/inet addr/{print substr($2,6)}')
if [ $? -ne 0 ]; then
   echo "No DHCP services, please check DHCP server."
else
   echo "eth1 IP: $IP"
   log_and_exec "docker exec $NAME ifconfig br0 $IP"
   log_and_exec "docker exec $NAME ifconfig br0 0.0.0.0"
#   log_and_exec "docker exec $NAME ifconfig eth1 0.0.0.0"
fi

log_and_exec "docker exec $NAME infrasim node start"
