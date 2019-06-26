#!/bin/bash 

##
## ebs_ctl.sh
## locate, attach, partition, format, detach ebs volumes
## 
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export AWS_DEFAULT_REGION='us-west-1'

## functions
function die { echo "$*" 1>&2 && exit 1; }

function get_instance_id {
  curl -s http://169.254.169.254/latest/meta-data/instance-id ||
    die "${FUNCNAME[0]}: can't get instance-id"
}

function get_asg_name {
  local instance_id=$1
  local json=$(aws autoscaling describe-auto-scaling-instances --instance-id=${instance_id})
  ## if instance is part of an asg, it returns an array with a single element
  local length=$(echo ${json} | jq '.[] | length')
  [[ $length ]] && echo $json | jq -r .AutoScalingInstances[].AutoScalingGroupName ||
    die "${FUNCNAME[0]}: can't get autoscaling group name"
}

function get_volume_id {
  local json=$1
  [[ -e $json ]] && jq -r .Volumes[].VolumeId $json ||
    die "${FUNCNAME[0]}: volume_id not found"
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

function ebs_defaults {
  ## fetch instance_id
  local instance_id=$(get_instance_id)
  local asg_name=$(get_asg_name ${instance_id})
  ## ebs is tagged with same name as autoscaling group
  local json=$(fetch_ebs_data $asg_name)
  local volume_id=$(get_volume_id $json)
  ## overwrite existing defaults file
  local defaults=/etc/default/ebs
  [[ -e /etc/default/ebs ]] && rm /etc/default/ebs
  for env in instance_id asg_name volume_id; do
    echo "${env^^}=${!env}" | dd of=${defaults} oflag=append conv=notrunc status=none
  done
  [[ -e $defaults ]] && source $defaults ||
      die "${FUNCNAME[0]}: can't source $defaults"
}

function attach_volume {
  local volume_id=$1
  local instance_id=$2
  local device=$3
  aws ec2 attach-volume --volume-id ${volume_id} --instance-id ${instance_id} --device ${device}
}

function detach_volume {
  local volume_id=$1
  aws ec2 detach-volume --volume-id ${volume_id}
}

function link_home {
  ## relocate home directory
  local mount=$1
  local home=$2
  ## check if home directory exists
  ## assume target disk is mounted
  [[ -e $home ]] &&
    ( rsync -Rq $home $mount
      rm -rf $home
      ln -s ${mount}/${home#/} $home )
}

function make_fs {
  local part=$1
  local fstype=$2
  [[ "$(lsblk -o FSTYPE $part --json | jq -r .blockdevices[].fstype)" == 'null' ]] &&
    sudo mkfs.$fstype -q $part
}

function make_part {
  local device=$1
  ## wait for disk to appear
  poll_device $device
  partition $device
  printf "%s%s" ${device} 1
}

function mount_disk {
  local part=$1
  local mount=$2
  grep -qs ${mount} /proc/mounts ||
    ( sudo mount $part $mount
      sudo touch /${mount}/$(date +%Y-%m-%d-%H:%M:%S) )
}

function partition {
  local device=$1
  ## check to see if disk is already partitioned
  [[ "$(lsblk -o PARTUUID $device --json | jq -r .blockdevices[].partuuid)" == 'null' ]] &&
    (( echo o ## create empty dos partition table
       echo n ## add a new partition
       echo p ## primary partition
       echo 1 ## partition number
       echo   ## first sector (defaults)
       echo   ## last sector  (defaults)
       echo w ) | sudo fdisk $device )
}

function poll_device {
  local device=$1
  ## poll every second until disk appears
  while [[ ! $(df -T ${device}) ]]; do sleep 1; done
}

function umount_disk {
  local part=$1
  local mount=$2
  grep -qs $mount /proc/mounts &&
    sudo umount $mount
}

function update_fstab {
  local part=$1
  local mount=$2
  local uuid=$(blkid | grep $part | awk {'print $2'} | sed -e 's/"//g')
  [[ -z $(grep $uuid /etc/fstab) ]] &&
    printf "%s %s ext4 defaults 0 2\n" $uuid $mount | sudo tee -a /etc/fstab
}

function usage { echo "$0 -d [device] -m [mount point] -v [volume_id] -h [home]" && exit; }
## end functions

## main
while getopts "d:h:m:v:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    h) home=$OPTARG ;;
    m) mount=$OPTARG ;;
    v) volume_id=$OPTARG ;;
    *) usage ;;
  esac
done

## volume_id is used by fdisk module
[[ -z $device ]] && [[ -z $volume_id ]] && usage
## set default mount point and ensure it exists
[[ -z $mount ]] && mount='/export'
[[ -d $mount ]] || mkdir -p $mount

## volume_id is only used by fdisk module
[[ ! -z $volume_id ]] && 
  ( attach_volume $volume_id $(get_instance_id) /dev/xvdz 
    part=$(make_part /dev/xvdz)
    make_fs $part ext4
    mount_disk $part /mnt
    umount_disk $part /mnt 
    detach_volume $volume_id )

## device is used by systemd script
[[ ! -z $device ]] && [[ -z $volume_id ]] &&
  ( ebs_defaults
    attach_volume $VOLUME_ID $INSTANCE_ID $device
    ## disk is usually partitioned and formatted
    part=$(make_part /dev/xvdz)
    make_fs $part ext4
    update_fstab $part $mount
    mount_disk $part $mount    
    [[ -z $home ]] || link_home $mount $home )

## end main
