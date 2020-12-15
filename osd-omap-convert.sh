#!/bin/bash
set -e


display_usage() {
  echo "Usage: $0 <osd_id> [rocksdb|leveldb]"
  echo "If the target omap param is not provided, the script will default to rocksdb"
  echo
}

# This may be required for ceph-osdomap-tool
ulimit -n 65535

echo

OSD_ID=$1

if [ "${OSD_ID}" == "" ]; then
  display_usage
  exit 1
fi

case $2 in
  leveldb)
    OMAP_TO=leveldb
    OMAP_FROM=rocksdb
  ;;
  rocksdb)
    OMAP_TO=rocksdb
    OMAP_FROM=leveldb
  ;;
  *)
    echo "Defaulting to rocksdb"
    OMAP_TO=rocksdb
    OMAP_FROM=leveldb
  ;;
esac

if [ ! -f "/var/lib/ceph/osd/ceph-${OSD_ID}/superblock" ]; then
  echo "### No superblock file found for ${OSD_ID}"
  exit 1
fi

OMAP_FORMAT=$(egrep -ao 'leveldb|rocksdb' "/var/lib/ceph/osd/ceph-${OSD_ID}/superblock")

if [ "${OMAP_FORMAT}" == "${OMAP_TO}" ]; then
  echo "### OMAP format for OSD ${OSD_ID} is already ${OMAP_TO}"
  exit 0
fi

if [ "${OMAP_FORMAT}" != "${OMAP_FROM}" ]; then
  echo "### OMAP format for OSD ${OSD_ID} is not ${OMAP_FROM}"
  exit 1
fi

echo

if [ -e "/var/lib/ceph/osd/ceph-${OSD_ID}/omap.orig" ]; then
  echo "### Directory exists /var/lib/ceph/osd/ceph-${OSD_ID}/omap.orig - taking no action"
  exit 1
fi


echo "### Converting OSD ${OSD_ID} omap ${OMAP_FROM}->${OMAP_TO}"

echo "### Stopping OSD ceph-osd@${OSD_ID}"
systemctl stop "ceph-osd@${OSD_ID}"

# Wait for up to a minute for the osd daemon to stop
TRIES=12
COUNT=1
while [ $COUNT -lt $TRIES ]; do
  systemctl is-active "ceph-osd@${OSD_ID}" > /dev/null 2>&1 || break
  echo "### Waiting 5s for ceph-osd@${OSD_ID} to stop (${COUNT}/${TRIES})"
  sleep 5s
  COUNT=$[$COUNT+1]
done

if [ $COUNT -ge $TRIES ]; then
  echo "### OSD daemon ceph-osd@${OSD_ID} did not stop in time"
  exit 1
fi

echo "### Repairing ${OMAP_FROM} in /var/lib/ceph/osd/ceph-${OSD_ID}/current/omap"
ceph-osdomap-tool --omap-path "/var/lib/ceph/osd/ceph-${OSD_ID}/current/omap" --backend ${OMAP_FROM} --command repair
echo "### Compacting ${OMAP_FROM} in /var/lib/ceph/osd/ceph-${OSD_ID}/current/omap"
ceph-osdomap-tool --omap-path "/var/lib/ceph/osd/ceph-${OSD_ID}/current/omap" --backend ${OMAP_FROM} --command compact

echo "### Moving current/omap directory to omap.orig for OSD ${OSD_ID}"
mv "/var/lib/ceph/osd/ceph-${OSD_ID}/current/omap" "/var/lib/ceph/osd/ceph-${OSD_ID}/omap.orig"

echo "### Converting OSD ${OSD_ID} omap from ${OMAP_FROM} to ${OMAP_TO}"
ceph-kvstore-tool ${OMAP_FROM} "/var/lib/ceph/osd/ceph-${OSD_ID}/omap.orig" store-copy "/var/lib/ceph/osd/ceph-${OSD_ID}/current/omap" 10000 ${OMAP_TO}

echo "### Checking ${OMAP_TO} osdomap for OSD ${OSD_ID}"
ceph-osdomap-tool --omap-path "/var/lib/ceph/osd/ceph-${OSD_ID}/current/omap" --backend ${OMAP_TO} --command check

echo "### Updating OSD ${OSD_ID} superblock to reflect omap is now ${OMAP_TO}"
sed -i -e s/${OMAP_FROM}/${OMAP_TO}/g "/var/lib/ceph/osd/ceph-${OSD_ID}/superblock"

echo "### Resetting ownership on /var/lib/ceph/osd/ceph-${OSD_ID}/current/omap"
chown -R ceph:ceph "/var/lib/ceph/osd/ceph-${OSD_ID}/current/omap"

echo "### Removing /var/lib/ceph/osd/ceph-${OSD_ID}/omap.orig recursively"
rm -rf "/var/lib/ceph/osd/ceph-${OSD_ID}/omap.orig"

echo "### Starting OSD ceph-osd@${OSD_ID}"
systemctl start "ceph-osd@${OSD_ID}"

# This loop checks the status of the OSD to see if it's up+in.  If not, it sleeps and retries
TRIES=24
COUNT=1
while [ $COUNT -lt $TRIES ]; do
  OSDDUMP=$(sudo ceph osd dump -f json | jq -r ".osds[] | select(.osd==${OSD_ID}) | select(.in==1) | select(.up==1)")
  if [ "${OSDDUMP}" == "" ]; then
    echo "### Waiting 5s for OSD ${OSD_ID} to be up and in (${COUNT}/${TRIES})"
    sleep 5s
    COUNT=$[$COUNT+1]
  else
    break
  fi 
done

if [ $COUNT -ge $TRIES ]; then
  echo "### OSD ${OSD_ID} failed to be up+in before timeout"
  exit 1
fi

echo "### OSD ${OSD_ID} ${OMAP_FROM}->${OMAP_TO} completed"

