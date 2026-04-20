#!/bin/sh

# Copyright 2026 The KMDB Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Useful for debugging:
# ./sync_copy.sh |& tee sync_copy.log

echo This demo script walks through how you sync a database that has been copied using the filesystem [cp -R]

# Remove the demo directories if they exist:
rm -rf copydb*
rm -rf remote_mount/copydb_sync

echo Creating copydb_og with a new note:
dart run ../../bin/kmdb.dart copydb_og insert notes --value '{"title": "Original note"}'
dart run ../../bin/kmdb.dart copydb_og scan notes

echo making a copy of the database:
# Use the filesystem to copy the database directory:
cp -R copydb_og copydb_copy

echo checking that the copied DB has the note:
# We should see the original note:
dart run ../../bin/kmdb.dart copydb_copy scan notes

echo These are the deviceIDs for the 2 databases [they will be the same]
echo copydb_og: $(dart run ../../bin/kmdb.dart copydb_og info | jq '.deviceId')
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy info | jq '.deviceId')

echo Configuring the remote for the databases:
dart run ../../bin/kmdb.dart copydb_og remote add origin --path $PWD/remote_mount/copydb_sync
dart run ../../bin/kmdb.dart copydb_copy remote add origin --path $PWD/remote_mount/copydb_sync

# When you now sync you'll see that it looks like the data is from the same deviceId
echo Performing a sync for each database
dart run ../../bin/kmdb.dart copydb_og sync
dart run ../../bin/kmdb.dart copydb_copy sync

echo Creating a new note in copydb_og and syncing it
dart run ../../bin/kmdb.dart copydb_og insert notes --value '{"title": "Original note - the sequel"}'
dart run ../../bin/kmdb.dart copydb_og sync

echo Sync to the copy
dart run ../../bin/kmdb.dart copydb_copy sync

echo The scan unfortunately displays only 1 note:
dart run ../../bin/kmdb.dart copydb_copy scan notes

echo We need to create a new device ID for the copy:
OLD_DEVICE_ID=$(dart run ../../bin/kmdb.dart copydb_copy info | jq '.deviceId')
echo copydb_copy before new-device-id: $OLD_DEVICE_ID

dart run ../../bin/kmdb.dart copydb_copy new-device-id
echo copydb_copy after new-device-id: $(dart run ../../bin/kmdb.dart copydb_copy info | jq '.deviceId')

echo Now sync the copy [with the new device ID set up]
dart run ../../bin/kmdb.dart copydb_copy sync

echo Deleting the hwm file: $PWD/remote_mount/copydb_sync/highwater/$OLD_DEVICE_ID
rm $PWD/remote_mount/copydb_sync/highwater/$OLD_DEVICE_ID

echo Syncing both databases
echo copydb_og: $(dart run ../../bin/kmdb.dart copydb_og sync)
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy sync)

echo The copydb_og database should have both notes:
dart run ../../bin/kmdb.dart copydb_og scan notes

echo The copydb_copy database should also now have both notes:
dart run ../../bin/kmdb.dart copydb_copy scan notes

echo These are now the deviceIDs for the 2 databases:
echo copydb_og: $(dart run ../../bin/kmdb.dart copydb_og info | jq '.deviceId')
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy info | jq '.deviceId')

echo Sync a few more times to ensure the device ID is stable
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy sync)
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy sync)
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy sync)
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy sync)
echo copydb_copy: $(dart run ../../bin/kmdb.dart copydb_copy sync)
