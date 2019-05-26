#!/bin/bash
# This script create a new LVM filesystem or extend current filesystem, the EBS volume creation
# expansion is in separate Powershell script
# This script is called by VRO workflow "Create and Attach AWS disk" and "Expand AWS Disk"
# Liz Yu 26-10-2018 Initial commit
# Liz Yu 30-10-2018 Added checks to stop mounting over the root filesystems
# Liz Yu 01-11-2018 Modified VGNAME and LVNAME to the mountpoint name
# Liz Yu 12-11-2018 Added logger function for debugging, standard output and error logged in /var/log/scriptname.log




PATH=/bin:/sbin:/usr/bin
ROOTDISK=`df -h | grep /$| awk '{ print $1 }'`
MOUNTPOINT=$1
OPTION=$2
LOGFILE="/var/log/`basename "$0"| sed 's/sh/log/'`"


logger(){


    echo `date +'%d %b %Y %r '` "$@" >> $LOGFILE
}


die(){


    echo "$@" |& tee -a $LOGFILE
    exit 1
}


validate_input_params(){


    [ $UID -ne 0 ] && die "This script must be run as root"
    [ "$#" -lt 2 ] || \
        die "Usage  : <script name> <mountpoint> <action>
            Action : create or expand
            Example: create_lv_fs.sh /data create"


}


wait_new_disk(){


    # keep scanning until new disk found
    # found the number of disks which are in-used
    DISKCOUNT=0
    for disk in `lsblk|grep -v xvda|grep ^xvd | cut -c 1-4`
    do
        found=`file -s /dev/"$disk" | awk '$2 == "LVM2" {print $2}'`
        [ ! -z $found ] && DISKCOUNT=`expr $DISKCOUNT + 1`
    done


    echo "Number of disk in-used are $DISKCOUNT"| tee -a $LOGFILE
    EXPECTDISKCOUNT=`expr $DISKCOUNT + 1`
    echo "Number of disk after new disk is $EXPECTDISKCOUNT"| tee -a $LOGFILE


    while [ $DISKCOUNT != $EXPECTDISKCOUNT ]
    do
        echo "- - -" > /sys/class/scsi_host/host0/scan
        DISKCOUNT=`lsblk | grep -v xvda | grep ^xvd | wc -l`
        echo "disk count is $DISKCOUNT" | tee -a $LOGFILE
    done


}




determine_new_disk(){


    sleep 10


    ALLDISKS=`lsblk -pldno NAME |grep -v xvda$`
    for disk in $ALLDISKS
    do
        NEWDISK=`file -s $disk | awk '$2 == "data" { print $1 }' | sed 's/:$//'`
        if [ ! -z $NEWDISK ]
        then
            logger "New disk is $disk"
            NEWDISK_FOUND=true
            break
        else
            logger "No new disk found, $disk is not new"
        fi
    done


}




validate_new_mountpoint(){


    # If root filesystems then exit
    case $MOUNTPOINT in
        /|/usr|/opt|/var|/tmp|/etc|/dev|usr|opt|var|tmp|etc|dev)
            die "New mountpoint cannot be any of the root filesystems"
            ;;
    esac


    # exit if mountpoint already exist
    grep -qs '$MOUNTPOINT' /proc/mounts
    [ $? == 0 ] && die "Mountpoint in use, choose another one"


    # insert leading / if not exist
    if [ "`echo $MOUNTPOINT|cut -c1`" != "/" ]
    then
        MOUNTPOINT=`echo $MOUNTPOINT | sed 's/^/\//'`
        logger "Added leading / on the mountpoint"
    fi


    # ensure only alphanumeric characters, no more than 8
    [ `echo $MOUNTPOINT | egrep -o '^\/[[:alnum:]]{1,8}$'` ] \
        || die "Mountpoint needs to be less than 8 alphanumeric characters"


}


install_lvm(){


    pvs > /dev/null 2>&1
    [ $? == 127 ] && yum install lvm2 -y
    count=`rpm -aq | grep lvm2 | wc -l`
    [ $count -lt 1 ] && die "LVM has not been installed successfully"


}


create_filesystem(){


    [ "$NEWDISK" == "$ROOTDISK" ] && die "New disk should not be the root disk"
    [ -z "$NEWDISK" ] && die "New disk is empty"


    # Set the VGNAME and LVNAME
    [ "`echo $MOUNTPOINT|cut -c1`" == "/" ]  \
        && VGNAME=`echo $MOUNTPOINT | sed 's/^.//;s/$/vg/'` \
        && LVNAME=`echo $MOUNTPOINT | sed 's/^.//;s/$/vol/'`


    logger "pvcreate $NEWDISK"
    pvcreate $NEWDISK |& tee -a $LOGFILE
    logger "vgcreate $VGNAME $NEWDISK"
    vgcreate $VGNAME $NEWDISK |& tee -a $LOGFILE
    logger "lvcreate -l 100%FREE -n $LVNAME $VGNAME -y"
    lvcreate -l 100%FREE -n $LVNAME $VGNAME -y |& tee -a $LOGFILE
    logger "mkfs.xfs /dev/$VGNAME/$LVNAME"
    mkfs.xfs /dev/$VGNAME/$LVNAME |& tee -a $LOGFILE
    logger "New filesystem has been created"


}


mount_filesystem(){


    [ ! -d $MOUNTPOINT ] && mkdir -p $MOUNTPOINT
    mount /dev/$VGNAME/$LVNAME $MOUNTPOINT
    logger "$MOUNTPOINT has been mounted successfully"


}


update_fstab(){


    if [ `grep $MOUNTPOINT /etc/fstab | wc -l` == 0 ]
    then
        echo "/dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT xfs defaults 0 0" >> /etc/fstab
        logger "$MOUNTPOINT has been added to fstab"
    else
        logger "fstab update not required, $MOUNTPOINT already exist"
    fi


}


validate_existing_mountpoint(){


    case $MOUNTPOINT in
        /|/usr|/opt|/var|/tmp|/run|/dev|/etc|usr|opt|var|tmp|run|dev|etc)
            die "root filesystem is not resizable"
            ;;
    esac


    #ensure it is mounted prior to expansion
    MOUNTED=`findmnt -n --target $MOUNTPOINT | awk '{ print $1 }'`
    [ -z $MOUNTED ] && die "Invalid mountpoint $MOUNTPOINT"
    [ $MOUNTED == $MOUNTPOINT ] || mount $MOUNTPOINT


}


detect_capacity_change(){


    count=1
    logger "Detect capacity change"
    while [ $count -lt "10" ]
    do
        tail /var/log/messages | grep "detected capacity change"
        [ $? == 0 ] && break || sleep 5
        count=`expr $count + 1`
    done
    [ $count == 10 ] && die "EBS vol has not been resized"


}


resize_existing_filesystem(){


    # wait for 10 sec for the EBS vol to resize
    sleep 10


    if [ `grep "$MOUNTPOINT"vg /etc/fstab | wc -l` == 1 ]
    then
        BLOCK_DEV=`grep "$MOUNTPOINT"vg /etc/fstab | awk -F / '{ print $(NF-1) }'`
        MOUNT_VG=`echo $BLOCK_DEV | cut -d\- -f1`
        MOUNT_LV=`echo $BLOCK_DEV | cut -d\- -f2`
        MOUNT_DISK=`pvs | grep $MOUNT_VG | awk '{ print $1 }'`
        logger "pvresize $MOUNT_DISK"
        pvresize $MOUNT_DISK |& tee -a $LOGFILE
        logger "lvextend -l +100%FREE /dev/$MOUNT_VG/$MOUNT_LV"
        lvextend -l +100%FREE /dev/$MOUNT_VG/$MOUNT_LV |& tee -a $LOGFILE
        logger "xfs_growfs -d $MOUNTPOINT"
        xfs_growfs -d $MOUNTPOINT |& tee -a $LOGFILE
        logger "$MOUNTPOINT has been resize"
    else
        die "This mountpoint has more than 1 entry in fstab"
    fi


}


logger "Script start"
case $OPTION in
    create)
        logger "Start: $MOUNTPOINT LVM creation"
        determine_new_disk
        while [ "$NEWDISK_FOUND" != "true" ]
        do
            wait_new_disk
            determine_new_disk
        done
        validate_new_mountpoint
        install_lvm
        create_filesystem
        update_fstab
        mount_filesystem
        ;;
    expand)
        logger "Start: $MOUNTPOINT LVM expansion"
        validate_existing_mountpoint
        detect_capacity_change
        resize_existing_filesystem
        ;;
    *)
        die "Unknown mountpoint option, please enter "expand" or "create""
        ;;
esac
logger "Script finished"
