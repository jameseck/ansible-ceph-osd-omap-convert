This repo contains an ansible playbook designed to convert OSD omap stores from leveldb to rocksdb
It is designed to process OSDs sequentially on each OSD node but across multiple OSD nodes at once.
Caution should be exercised with how many OSD nodes are provided to the playbook.
You need to determine the Crush failure domain when deciding how many OSD's to convert concurrently.
