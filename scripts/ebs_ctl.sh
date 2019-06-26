#!/bin/bash 

##
## ebs_ctl.sh
## locate, attach, detach ebs volumes
## 
PATH=/bin:/sbin:/usr/bin:/usr/sbin

## functions
function attach_volume {
  local volume_id=$1
  local instance_id=$2
  local device=$3
  aws ec2 attach-volume --volume-id ${volume_id} --instance-id ${instance_id} --device ${device} &&
    poll_device $device || true
}

function detach_volume {
  local volume_id=$1
  aws ec2 detach-volume --volume-id ${volume_id}
}

function die { echo "$*" 1>&2 && exit 1; }

function ebs_defaults {
  ## fetch instance_id
  local instance_id=$(get_instance_id)
  local asg_name=$(get_asg_name ${instance_id})
  ## ebs is tagged with same name as autoscaling group
  local json=$(fetch_ebs_data $asg_name)
  local volume_id=$(get_volume_id $json)
  local aws_default_region=$(get_region)
  ## overwrite existing defaults file
  local defaults=/etc/default/ebs
  [[ -e /etc/default/ebs ]] && rm /etc/default/ebs
  for env in instance_id asg_name volume_id aws_default_region; do
    echo "${env^^}=${!env}" | dd of=${defaults} oflag=append conv=notrunc status=none
  done
  [[ -e $defaults ]] && source $defaults ||
      die "${FUNCNAME[0]}: can't source $defaults"
}

function fetch_ebs_data {
  ## the name of the ebs volume matches the autoscaling group name
  local asg_name=$1
  local json='/tmp/.ebs.json'
  local filter="--filter Name=tag:Name,Values=${asg_name}"
  local cmd="/usr/bin/aws ec2 describe-volumes ${filter} > ${json}"
  local output=$(eval "$cmd")
  [[ $? == 0 ]] && echo $json || die "failed to fetch ebs data: ${output//$'\n'}"
}

function get_asg_name {
  local instance_id=$1
  local json=$(aws autoscaling describe-auto-scaling-instances --instance-id=${instance_id})
  ## if instance is part of an asg, it returns an array with a single element
  local length=$(echo ${json} | jq '.[] | length')
  [[ $length ]] && echo $json | jq -r .AutoScalingInstances[].AutoScalingGroupName ||
    die "${FUNCNAME[0]}: can't get autoscaling group name"
}

function get_instance_id {
  curl -s http://169.254.169.254/latest/meta-data/instance-id ||
    die "${FUNCNAME[0]}: can't get instance-id"
}

function get_region {
  local availability_zone=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/)
  printf "%s\n" ${availability_zone%%[a-z]}
}

function get_volume_id {
  local json=$1
  [[ -e $json ]] && jq -r .Volumes[].VolumeId $json ||
    die "${FUNCNAME[0]}: volume_id not found"
}

function link_home {
  ## relocate home directory
  local mount=$1
  local users=(${2//,/ })
  ## make sure home exists on mount
  [[ -d ${mount}/home ]] || mkdir ${mount}/home
  for user in "${users[@]}"; do 
    [[ -d /home/${user} ]] &&
      ( [[ -L /home/${user} ]] && continue ||
        ( rsync -Rq /home/${user} ${mount}/home
          [[ -d /home/.${user} ]] && rm -rf /home/.${user}
          mv /home/${user} /home/.${user}
          chown -R ${user}:${user} /home/.${user}
          chown -R ${user}:${user} /export/home/${user}
          ln -s ${mount}/home/${user} /home/${user} ))
  done
}

function mount_disk {
  local part=$1
  local mount=$2
  grep -qs $mount /proc/mounts || sudo mount $part /${mount}
}

function poll_device {
  local device=$1
  ## poll every second until disk appears
  while [[ ! $(df -T ${device}) ]]; do sleep 1; done
}

function update_fstab {
  local part=$1
  local mount=$2
  local uuid=$(blkid | grep $part | awk {'print $2'} | sed -e 's/"//g')
  [[ -z $(grep $uuid /etc/fstab) ]] &&
    printf "%s %s ext4 defaults 0 2\n" $uuid $mount | sudo tee -a /etc/fstab
}

function usage { echo "$0 -d [device] -m [mount point] -v [volume_id] -u [user1,user2]" && exit; }
## end functions

## main
while getopts "d:m:u:v:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    m) mount=$OPTARG ;;
    u) users=$OPTARG ;;
    *) usage ;;
  esac
done

## set default mount point
[[ -z $mount ]] && mount='/export'

## set region
export AWS_DEFAULT_REGION=$(get_region)

## require device
[[ -z $device ]] && usage ||
  ( ebs_defaults
    [[ -d $mount ]] || mkdir -p /${mount}
    attach_volume $VOLUME_ID $INSTANCE_ID $device
    ## disk is usually partitioned and formatted
    partition=$(printf "%s%s" ${device} 1)
    update_fstab $partition $mount
    mount_disk $partition $mount    
    [[ -z $users ]] || link_home $mount $users )
## end main
